defmodule SymphonyElixir.Orchestrator.RetryPolicy do
  @moduledoc """
  Decides retry behavior for a failed agent run based on the structured error
  code IDE-71's adapter classification surfaces.

  Each error code has a `strategy` (`:backoff` or `:no_retry`) plus, for
  `:backoff`, a `base_ms` / `max_ms` window and whether to honor any upstream
  `Retry-After` hint. Defaults are baked in (see `built_in_for/2`); operators
  override per code via `agent.retry_policy.<code>` in WORKFLOW.md.
  """

  alias SymphonyElixir.Config.Schema

  import Bitwise, only: [<<<: 2]

  @typedoc "Outcome of a policy lookup."
  @type decision :: {:retry, pos_integer()} | :no_retry

  @typedoc "Resolved policy entry."
  @type entry :: %{
          strategy: :backoff | :no_retry,
          base_ms: pos_integer(),
          max_ms: pos_integer(),
          honor_retry_after: boolean()
        }

  @recognized_codes ~w(
    rate_limited
    overloaded
    context_window_exhausted
    quota_exceeded
    invalid_request
    budget_exhausted
    max_turns_reached
    unknown
  )a

  @doc """
  Return the recognized error codes (excluding the implicit `:default`).
  """
  @spec recognized_codes() :: [atom(), ...]
  def recognized_codes, do: @recognized_codes

  @doc """
  Resolve the per-code policy from the supplied settings, merging operator
  overrides on top of the built-in defaults.
  """
  @spec resolve(atom(), Schema.t() | map() | nil) :: entry()
  def resolve(error_code, settings) do
    code = normalize_code(error_code)
    policy_map = retry_policy_map(settings)
    code_override = lookup_policy(policy_map, Atom.to_string(code))
    cap = max_retry_backoff_ms(settings)

    code
    |> built_in_for(cap)
    |> merge_override(code_override, cap)
  end

  @doc """
  Decide whether to retry for the given error code on the given attempt.

  `attempt` is the 1-based attempt number for the upcoming retry (matching
  `Orchestrator.schedule_issue_retry/4`). `retry_after_ms` may be `nil`.

  Returns `{:retry, delay_ms}` or `:no_retry`.
  """
  @spec decide(atom(), pos_integer(), pos_integer() | nil, Schema.t() | map() | nil) :: decision()
  def decide(error_code, attempt, retry_after_ms, settings) when attempt > 0 do
    error_code
    |> resolve(settings)
    |> decision_for(attempt, retry_after_ms)
  end

  defp decision_for(%{strategy: :no_retry}, _attempt, _retry_after_ms), do: :no_retry

  defp decision_for(%{strategy: :backoff} = entry, attempt, retry_after_ms) do
    delay =
      if entry.honor_retry_after and is_integer(retry_after_ms) and retry_after_ms > 0 do
        min(retry_after_ms, entry.max_ms)
      else
        backoff_delay(entry.base_ms, entry.max_ms, attempt)
      end

    {:retry, max(delay, 1)}
  end

  defp backoff_delay(base_ms, max_ms, attempt) do
    power = min(attempt - 1, 10)
    min(base_ms * (1 <<< power), max_ms)
  end

  # A Claude subscription usage-limit can be hours away — honor the real reset
  # (carried as the sidecar-embedded `retry-after <seconds>`) up to a 6h ceiling
  # rather than re-hitting the wall after 15 min. Kept separate from
  # `:overloaded` so a transient 503's seconds-scale `retry-after` can't be
  # widened by a malformed hint into a multi-hour strand.
  defp built_in_for(:rate_limited, _cap),
    do: %{strategy: :backoff, base_ms: 30_000, max_ms: 6 * 3_600_000, honor_retry_after: true}

  defp built_in_for(:overloaded, cap),
    do: %{strategy: :backoff, base_ms: 30_000, max_ms: max(cap, 900_000), honor_retry_after: true}

  defp built_in_for(code, _cap)
       when code in [:context_window_exhausted, :quota_exceeded, :invalid_request, :budget_exhausted],
       do: %{strategy: :no_retry, base_ms: 0, max_ms: 0, honor_retry_after: false}

  # IDE-74: max_turns_reached is the "ran out of agent.max_turns budget" signal.
  # Match the existing `:normal`-exit continuation cadence (1s constant) so the
  # follow-up run kicks off promptly while IDE-73's deterministic-failure
  # counter advances on each consecutive cap-hit and posts the workpad alert /
  # escalates the issue after the configured thresholds.
  defp built_in_for(:max_turns_reached, _cap),
    do: %{strategy: :backoff, base_ms: 1_000, max_ms: 1_000, honor_retry_after: false}

  defp built_in_for(_code, cap),
    do: %{strategy: :backoff, base_ms: 10_000, max_ms: cap, honor_retry_after: false}

  defp normalize_code(code) when is_atom(code) and code in @recognized_codes, do: code
  defp normalize_code(_other), do: :unknown

  # Tests inject the agent block directly; production passes a `%Schema{}`
  # struct from `Config.settings!/0` and the `%{agent: …}` clause picks both up.
  defp retry_policy_map(%{agent: %{retry_policy: policy}}) when is_map(policy), do: policy
  defp retry_policy_map(%{retry_policy: policy}) when is_map(policy), do: policy
  defp retry_policy_map(_settings), do: %{}

  defp max_retry_backoff_ms(%{agent: %{max_retry_backoff_ms: ms}})
       when is_integer(ms) and ms > 0,
       do: ms

  defp max_retry_backoff_ms(%{max_retry_backoff_ms: ms}) when is_integer(ms) and ms > 0, do: ms

  defp max_retry_backoff_ms(_settings), do: 300_000

  # Schema normalization stringifies keys, but tests may pass atom-keyed
  # overrides. Skip `String.to_existing_atom` rather than `String.to_atom` so
  # adversarial config can't bloat the atom table.
  defp lookup_policy(policy_map, key) when is_map(policy_map) and is_binary(key) do
    Map.get(policy_map, key) || atom_lookup(policy_map, key)
  end

  defp atom_lookup(policy_map, key) do
    Map.get(policy_map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp merge_override(entry, nil, _cap), do: entry

  defp merge_override(entry, override, cap) when is_map(override) do
    entry
    |> Map.put(:strategy, strategy_from(override, entry.strategy))
    |> Map.put(:base_ms, integer_field(override, "base_ms", entry.base_ms))
    |> Map.put(:max_ms, integer_field(override, "max_ms", entry.max_ms))
    |> Map.put(
      :honor_retry_after,
      boolean_field(override, "honor_retry_after", entry.honor_retry_after)
    )
    |> clamp_max_ms(cap)
  end

  defp strategy_from(override, default) do
    case fetch_string_field(override, "strategy") do
      "backoff" -> :backoff
      "no_retry" -> :no_retry
      _ -> default
    end
  end

  defp integer_field(override, key, default) do
    case fetch_field(override, key) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp boolean_field(override, key, default) do
    case fetch_field(override, key) do
      value when is_boolean(value) -> value
      _ -> default
    end
  end

  defp fetch_field(override, key) do
    case Map.fetch(override, key) do
      {:ok, value} -> value
      :error -> atom_lookup(override, key)
    end
  end

  defp fetch_string_field(override, key) do
    case fetch_field(override, key) do
      value when is_binary(value) -> value
      value when is_atom(value) and not is_nil(value) -> Atom.to_string(value)
      _ -> nil
    end
  end

  # `max_ms < base_ms` would silently turn into a hard cap below the desired
  # base — clamp upwards so the policy at least respects its own base.
  defp clamp_max_ms(%{strategy: :no_retry} = entry, _cap), do: entry

  defp clamp_max_ms(entry, _cap) do
    %{entry | max_ms: max(entry.max_ms, entry.base_ms)}
  end
end
