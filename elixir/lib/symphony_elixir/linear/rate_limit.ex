defmodule SymphonyElixir.Linear.RateLimit do
  @moduledoc """
  Process-wide circuit breaker for Linear GraphQL rate-limit responses.

  Linear's GraphQL endpoint enforces a per-token request budget (default
  2500 req/hr) and returns a `RATELIMITED` error with a
  `meta.rateLimitResult.duration` field indicating how many milliseconds
  remain until the window resets. Without coordination every poller and
  per-issue refresher keeps banging on the endpoint, exhausting the next
  window as soon as it opens and flooding the logs.

  Owns a single named ETS table that stores the next-allowed monotonic
  time. All Linear callers check `allowed?/0` before issuing a request
  and short-circuit with `{:error, :rate_limited}` if we are still inside
  the back-off window. Callers report a `RATELIMITED` response via
  `maybe_record_response/1`, which inspects the body and records the
  reset time when needed.
  """

  use GenServer
  require Logger

  @table :symphony_linear_rate_limit
  @reset_key :reset_at_ms
  @default_throttle_ms 60_000
  @ratelimited_code "RATELIMITED"
  @duration_paths [
    ["meta", "rateLimitResult", "duration"],
    ["extensions", "meta", "rateLimitResult", "duration"],
    ["rateLimitResult", "duration"]
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  True if no rate-limit window is active, or the recorded reset time has
  already passed.
  """
  @spec allowed?() :: boolean()
  def allowed? do
    case lookup_reset_at_ms() do
      nil -> true
      reset_at_ms -> System.monotonic_time(:millisecond) >= reset_at_ms
    end
  end

  @doc """
  Milliseconds remaining until the recorded reset time, or `nil` when no
  back-off is active.
  """
  @spec retry_after_ms() :: non_neg_integer() | nil
  def retry_after_ms do
    case lookup_reset_at_ms() do
      nil ->
        nil

      reset_at_ms ->
        max(0, reset_at_ms - System.monotonic_time(:millisecond))
    end
  end

  @doc """
  Returns `true` if `body` carries a `RATELIMITED` signal from Linear.
  """
  @spec rate_limited_body?(term()) :: boolean()
  def rate_limited_body?(%{"errors" => errors}) when is_list(errors) do
    Enum.any?(errors, fn
      %{"extensions" => %{"code" => @ratelimited_code}} -> true
      _ -> false
    end)
  end

  def rate_limited_body?(%{"meta" => %{"rateLimitResult" => %{"remaining" => remaining}}})
      when is_integer(remaining) and remaining <= 0,
      do: true

  # Defense against a proxy/CDN returning an undecoded JSON string or a plain
  # text throttle page (content-type Req leaves as a binary). Linear itself
  # always returns a decoded map, so this clause never fires for Linear proper.
  #
  # Match only the exact `RATELIMITED` code or narrow throttle-page wording.
  # A loose "rate limit" substring would mis-flag ordinary error text such as
  # "rate limit must be an integer" and needlessly pause all Linear traffic.
  def rate_limited_body?(body) when is_binary(body) do
    down = String.downcase(body)

    String.contains?(down, "ratelimited") or
      String.contains?(down, "rate limit exceeded") or
      String.contains?(down, "too many requests") or
      String.contains?(down, "429")
  end

  def rate_limited_body?(_body), do: false

  @doc """
  Returns `true` when the HTTP status code itself signals rate limiting.

  Restricted to `429` so the breaker does not arm on unrelated `400`/`5xx`
  responses; Linear's `400`-envelope carrying a `RATELIMITED` code is already
  caught by `rate_limited_body?/1`.
  """
  @spec rate_limited_status?(term()) :: boolean()
  def rate_limited_status?(429), do: true
  def rate_limited_status?(_status), do: false

  @doc """
  Inspect a Linear response body and record a back-off if it carries a
  `RATELIMITED` signal. Returns `:rate_limited` when a back-off was
  recorded, `:ok` otherwise.
  """
  @spec maybe_record_response(term()) :: :rate_limited | :ok
  def maybe_record_response(body) do
    if rate_limited_body?(body) do
      record_rate_limited(body)
      :rate_limited
    else
      :ok
    end
  end

  @doc """
  Like `maybe_record_response/1` but also arms the back-off when the HTTP
  status code alone signals rate limiting (a bare `429` whose body shape we
  cannot rely on). The body is still passed to `record_rate_limited/1` so the
  real `meta.rateLimitResult.duration` is used when present, falling back to
  the default throttle otherwise.
  """
  @spec maybe_record_response(term(), term()) :: :rate_limited | :ok
  def maybe_record_response(status, body) do
    if rate_limited_status?(status) or rate_limited_body?(body) do
      record_rate_limited(body)
      :rate_limited
    else
      :ok
    end
  end

  @doc """
  Record a rate-limit back-off. Accepts the parsed response body (in
  which case `meta.rateLimitResult.duration` is consulted), a raw
  duration in milliseconds, or `nil` to fall back to the default
  throttle.
  """
  @spec record_rate_limited(map() | non_neg_integer() | nil) :: non_neg_integer()
  def record_rate_limited(input) do
    now = System.monotonic_time(:millisecond)
    candidate_reset_at_ms = now + (extract_duration_ms(input) || @default_throttle_ms)

    # Never shorten an already-longer back-off: a bare 429 (60s fallback)
    # arriving after a one-hour window must not stomp the longer deadline.
    # Keep the later of the two and report the effective remaining duration.
    reset_at_ms = max(candidate_reset_at_ms, lookup_reset_at_ms() || now)
    :ets.insert(@table, {@reset_key, reset_at_ms})

    effective_ms = reset_at_ms - now
    Logger.warning("Linear API RATELIMITED; pausing Linear GraphQL traffic for #{effective_ms}ms")

    effective_ms
  end

  @doc """
  Clear any recorded back-off. Intended for tests and operator unblock.
  """
  @spec clear() :: :ok
  def clear do
    ensure_table()
    :ets.delete(@table, @reset_key)
    :ok
  end

  @impl true
  def init(_opts) do
    ensure_table()
    {:ok, %{}}
  end

  # The named table is created exactly once, in `init/1`. The GenServer owns it
  # with no heir, so a crashed owner takes the table down and a fresh `init/1`
  # always observes `:undefined`. Post-boot callers (`clear/0`) only ever see the
  # established table and take the `ref` branch, so `:ets.new/2` never races.
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:set, :named_table, :public, read_concurrency: true])
      ref -> ref
    end
  end

  defp lookup_reset_at_ms do
    case :ets.lookup(@table, @reset_key) do
      [{@reset_key, reset_at_ms}] -> reset_at_ms
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp extract_duration_ms(map) when is_map(map) do
    Enum.find_value(@duration_paths, fn path ->
      case get_in(map, path) do
        duration when is_integer(duration) and duration > 0 -> duration
        _ -> nil
      end
    end) || extract_duration_from_errors(map)
  end

  defp extract_duration_ms(duration) when is_integer(duration) and duration > 0, do: duration
  defp extract_duration_ms(_), do: nil

  defp extract_duration_from_errors(%{"errors" => errors}) when is_list(errors) do
    Enum.find_value(errors, fn
      %{"extensions" => extensions} when is_map(extensions) -> extract_duration_ms(extensions)
      _ -> nil
    end)
  end

  defp extract_duration_from_errors(_), do: nil
end
