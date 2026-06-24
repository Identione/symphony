defmodule SymphonyElixir.ProviderQuota do
  @moduledoc """
  Normalizes provider-specific account quota payloads into one snapshot shape.

  Both providers express bucket usage as a `used_percent` on a 0–100 scale:
  Codex's app-server `usedPercent` and the Anthropic OAuth usage endpoint's
  `utilization` are both already percentages (e.g. `72.5` = 72.5%), so they are
  carried through verbatim and compared directly against the configured
  `dispatch_pause_percent` threshold.
  """

  alias SymphonyElixir.MapAccess

  @type provider :: :codex | :claude

  @spec normalize_codex(map(), keyword()) :: map()
  def normalize_codex(%{} = payload, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    stale_after_ms = Keyword.get(opts, :stale_after_ms, 180_000)

    %{
      provider: :codex,
      source: "codex_app_server",
      fetched_at: DateTime.to_iso8601(DateTime.truncate(now, :second)),
      fetched_at_ms: now_ms,
      stale_after_ms: stale_after_ms,
      buckets: codex_buckets(payload),
      credits: codex_credits(payload),
      error: nil,
      raw: payload
    }
  end

  @spec normalize_claude(map(), keyword()) :: map()
  def normalize_claude(%{} = payload, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    stale_after_ms = Keyword.get(opts, :stale_after_ms, 180_000)

    %{
      provider: :claude,
      source: "anthropic_oauth_usage",
      fetched_at: DateTime.to_iso8601(DateTime.truncate(now, :second)),
      fetched_at_ms: now_ms,
      stale_after_ms: stale_after_ms,
      buckets: claude_buckets(payload),
      credits: claude_extra_usage(payload),
      error: nil,
      raw: payload
    }
  end

  @spec error_snapshot(provider(), term(), map(), map() | nil, keyword()) :: map()
  def error_snapshot(provider, reason, quota_config, previous \\ nil, opts \\ [])
      when provider in [:codex, :claude] and is_map(quota_config) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    stale_after_ms = map_value(quota_config, [:stale_after_ms, "stale_after_ms"]) || 180_000
    source = if provider == :claude, do: "anthropic_oauth_usage", else: "codex_app_server"

    base =
      previous ||
        %{
          provider: provider,
          source: source,
          buckets: %{},
          credits: nil,
          raw: nil
        }

    now_iso = DateTime.to_iso8601(DateTime.truncate(now, :second))

    # Preserve `fetched_at`/`fetched_at_ms` from the last *successful* fetch
    # (carried verbatim through `base`, which is either the previous snapshot or,
    # on a streak of failures, the previous error snapshot that already preserved
    # it). This keeps the snapshot's age tied to when the data was actually read,
    # so a telemetry outage eventually trips `stale?/2` — the card stops looking
    # perpetually fresh and stale buckets stop gating dispatch. When there has
    # never been a successful fetch, `base` carries no timestamp and the snapshot
    # reads as stale, which is correct: we have no fresh data to show.
    base
    |> Map.put(:stale_after_ms, stale_after_ms)
    |> Map.put(:error, sanitize_error(reason))
    |> Map.put(:error_since, error_since(base, now_iso))
    |> Map.put(:last_attempt_at, now_iso)
  end

  # First failure after a success (or ever): the streak starts now. On a
  # continuing streak `base` is the prior error snapshot carrying an `:error`
  # map, so preserve when the streak began.
  defp error_since(base, now_iso) do
    case map_value(base, [:error, "error"]) do
      %{} ->
        case map_value(base, [:error_since, "error_since"]) do
          since when is_binary(since) -> since
          _ -> now_iso
        end

      _ ->
        now_iso
    end
  end

  @spec active_quota_exhausted?(map() | nil, number(), integer()) :: boolean()
  def active_quota_exhausted?(nil, _threshold, _now_ms), do: false

  def active_quota_exhausted?(%{} = snapshot, threshold, now_ms)
      when is_number(threshold) and is_integer(now_ms) do
    not stale?(snapshot, now_ms) and
      snapshot
      |> Map.get(:buckets, %{})
      |> Enum.any?(fn {_name, bucket} ->
        case map_value(bucket, [:used_percent, "used_percent"]) do
          value when is_number(value) -> value >= threshold
          _ -> false
        end
      end)
  end

  def active_quota_exhausted?(_snapshot, _threshold, _now_ms), do: false

  @spec stale?(map(), integer()) :: boolean()
  def stale?(%{} = snapshot, now_ms) when is_integer(now_ms) do
    fetched_at_ms = map_value(snapshot, [:fetched_at_ms, "fetched_at_ms"])
    stale_after_ms = map_value(snapshot, [:stale_after_ms, "stale_after_ms"]) || 180_000

    not is_integer(fetched_at_ms) or now_ms - fetched_at_ms > stale_after_ms
  end

  def stale?(_snapshot, _now_ms), do: true

  defp codex_buckets(%{} = payload) do
    cond do
      is_map(map_value(payload, [:rateLimitsByLimitId, "rateLimitsByLimitId"])) ->
        payload
        |> map_value([:rateLimitsByLimitId, "rateLimitsByLimitId"])
        |> Enum.flat_map(fn {limit_id, snapshot} -> codex_snapshot_buckets(to_string(limit_id), snapshot) end)
        |> Map.new()

      is_map(map_value(payload, [:rateLimits, "rateLimits"])) ->
        payload
        |> map_value([:rateLimits, "rateLimits"])
        |> codex_snapshot_buckets("codex")
        |> Map.new()

      true ->
        limit_id =
          map_value(payload, [:limitId, "limitId", :limit_id, "limit_id", :limitName, "limitName", :limit_name, "limit_name"]) ||
            "codex"

        codex_snapshot_buckets(to_string(limit_id), payload) |> Map.new()
    end
  end

  defp codex_snapshot_buckets(limit_id, %{} = snapshot) do
    [:primary, :secondary]
    |> Enum.flat_map(fn bucket_name ->
      case map_value(snapshot, [bucket_name, Atom.to_string(bucket_name)]) do
        %{} = bucket ->
          [{"#{limit_id}.#{bucket_name}", normalize_codex_bucket(bucket)}]

        _ ->
          []
      end
    end)
  end

  defp codex_snapshot_buckets(_limit_id, _snapshot), do: []

  defp normalize_codex_bucket(%{} = bucket) do
    used_percent =
      map_value(bucket, [:usedPercent, "usedPercent", :used_percent, "used_percent"]) ||
        used_percent_from_remaining(bucket)

    %{
      used_percent: used_percent,
      resets_at: map_value(bucket, [:resetsAt, "resetsAt", :resets_at, "resets_at", :resetAt, "resetAt", :reset_at, "reset_at"]),
      window_minutes: map_value(bucket, [:windowDurationMins, "windowDurationMins", :window_duration_mins, "window_duration_mins"]),
      raw: bucket
    }
  end

  defp used_percent_from_remaining(%{} = bucket) do
    remaining = map_value(bucket, [:remaining, "remaining"])
    limit = map_value(bucket, [:limit, "limit"])

    if is_number(remaining) and is_number(limit) and limit > 0 do
      max(0, min(100, (limit - remaining) * 100 / limit))
    end
  end

  defp codex_credits(%{} = payload) do
    cond do
      is_map(map_value(payload, [:credits, "credits"])) ->
        map_value(payload, [:credits, "credits"])

      is_map(map_at_path(payload, [:rateLimits, :credits])) ->
        map_at_path(payload, [:rateLimits, :credits])

      is_map(map_at_path(payload, ["rateLimits", "credits"])) ->
        map_at_path(payload, ["rateLimits", "credits"])

      true ->
        nil
    end
  end

  defp claude_buckets(%{} = payload) do
    [
      "five_hour",
      "seven_day",
      "seven_day_sonnet",
      "seven_day_oauth_apps",
      "seven_day_opus",
      "seven_day_cowork",
      "seven_day_omelette",
      "omelette_promotional"
    ]
    |> Enum.flat_map(&claude_bucket_entry(payload, &1))
    |> Map.new()
  end

  defp claude_bucket_entry(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      %{} = bucket -> [{claude_bucket_name(key), normalize_claude_bucket(bucket)}]
      _ -> []
    end
  end

  defp claude_bucket_name("omelette_promotional"), do: "seven_day_design"
  defp claude_bucket_name("seven_day_omelette"), do: "seven_day_design"
  defp claude_bucket_name(key), do: key

  defp normalize_claude_bucket(%{} = bucket) do
    %{
      used_percent: map_value(bucket, [:utilization, "utilization"]),
      resets_at: map_value(bucket, [:resets_at, "resets_at", :resetsAt, "resetsAt"]),
      window_minutes: nil,
      raw: bucket
    }
  end

  defp claude_extra_usage(%{} = payload) do
    Map.get(payload, "extra_usage") || Map.get(payload, :extra_usage)
  end

  defp sanitize_error(reason) when is_atom(reason), do: %{code: Atom.to_string(reason)}
  defp sanitize_error({code, detail}) when is_atom(code), do: %{code: Atom.to_string(code), detail: inspect(detail, limit: 20)}
  defp sanitize_error(reason), do: %{code: "error", detail: inspect(reason, limit: 20)}

  defp map_value(map, keys), do: MapAccess.value(map, keys)
  defp map_at_path(map, path), do: MapAccess.at_path(map, path)
end
