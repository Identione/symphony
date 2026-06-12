defmodule SymphonyElixir.Claude.QuotaCollector do
  @moduledoc """
  Polls Claude Code's OAuth usage endpoint when explicitly enabled.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.{Config, Orchestrator, ProviderQuota}

  @default_endpoint "https://api.anthropic.com/api/oauth/usage"
  @default_beta "oauth-2025-04-20"
  @default_refresh_ms 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      orchestrator: Keyword.get(opts, :orchestrator, Orchestrator),
      http_client: Keyword.get(opts, :http_client, {Req, :get}),
      last_snapshot: nil
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    {delay_ms, state} = refresh(state)
    Process.send_after(self(), :refresh, delay_ms)
    {:noreply, state}
  end

  @spec fetch_once(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:error, term(), non_neg_integer() | nil}
  def fetch_once(%{} = settings, opts \\ []) do
    quota = settings.agent.claude.quota
    http_client = Keyword.get(opts, :http_client, {Req, :get})

    with {:ok, token} <- oauth_token(settings),
         {:ok, body} <- request_usage(http_client, quota, token) do
      {:ok, ProviderQuota.normalize_claude(body, stale_after_ms: quota.stale_after_ms)}
    end
  end

  @spec oauth_token(map()) :: {:ok, String.t()} | {:error, atom()}
  def oauth_token(%{} = settings) do
    case System.get_env("CLAUDE_CODE_OAUTH_TOKEN") do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        settings
        |> credentials_path()
        |> token_from_credentials_file()
    end
  end

  defp refresh(state) do
    case Config.settings() do
      {:ok, settings} ->
        refresh_with_settings(state, settings)

      {:error, reason} ->
        Logger.debug("Claude quota collector waiting for valid config: #{inspect(reason)}")
        {@default_refresh_ms, state}
    end
  end

  defp refresh_with_settings(state, settings) do
    quota = settings.agent.claude.quota
    delay_ms = refresh_delay(quota)

    if settings.agent.kind == "claude" and quota.enabled == true do
      state
      |> fetch_quota_snapshot(settings, quota, delay_ms)
    else
      {delay_ms, state}
    end
  end

  defp fetch_quota_snapshot(state, settings, quota, delay_ms) do
    case fetch_once(settings, http_client: state.http_client) do
      {:ok, snapshot} ->
        notify_orchestrator(state.orchestrator, snapshot)
        {delay_ms, %{state | last_snapshot: snapshot}}

      {:error, reason, retry_after_ms} ->
        notify_error_snapshot(state, quota, reason, retry_after_ms || delay_ms)

      {:error, reason} ->
        notify_error_snapshot(state, quota, reason, delay_ms)
    end
  end

  defp notify_error_snapshot(state, quota, reason, delay_ms) do
    snapshot = ProviderQuota.error_snapshot(:claude, reason, quota, state.last_snapshot)
    notify_orchestrator(state.orchestrator, snapshot)
    {delay_ms, %{state | last_snapshot: snapshot}}
  end

  defp refresh_delay(%{} = quota) do
    case Map.get(quota, :refresh_ms) do
      value when is_integer(value) and value > 0 -> value
      _ -> @default_refresh_ms
    end
  end

  defp notify_orchestrator(orchestrator, snapshot) do
    if Process.whereis(orchestrator) do
      send(orchestrator, {:provider_quota_snapshot, :claude, snapshot})
    end
  end

  defp request_usage({module, function}, quota, token) do
    endpoint = quota.endpoint || @default_endpoint

    headers = [
      {"authorization", "Bearer #{token}"},
      {"anthropic-beta", quota.anthropic_beta || @default_beta},
      {"user-agent", "claude-code/0.0.0"}
    ]

    case apply(module, function, [endpoint, [headers: headers, retry: false]]) do
      {:ok, %{status: 200, body: body}} ->
        decode_body(body)

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :auth_failed, nil}

      {:ok, %{status: 429, headers: headers}} ->
        {:error, :rate_limited, retry_after_ms(headers)}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}, nil}

      {:error, reason} ->
        {:error, {:network_error, reason}, nil}
    end
  end

  defp decode_body(%{} = body), do: {:ok, body}

  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = parsed} -> {:ok, parsed}
      {:ok, _other} -> {:error, :decode_error, nil}
      {:error, reason} -> {:error, {:decode_error, reason}, nil}
    end
  end

  defp decode_body(_body), do: {:error, :decode_error, nil}

  defp retry_after_ms(headers) do
    headers
    |> Enum.find_value(fn
      {"retry-after", value} -> value
      {"Retry-After", value} -> value
      _ -> nil
    end)
    |> case do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {seconds, _} when seconds >= 0 -> seconds * 1_000
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp credentials_path(%{agent: %{claude: %{config_dir: dir}}})
       when is_binary(dir) and dir != "" do
    Path.join(Path.expand(dir), ".credentials.json")
  end

  defp credentials_path(_settings) do
    cond do
      is_binary(System.get_env("CLAUDE_CONFIG_DIR")) and System.get_env("CLAUDE_CONFIG_DIR") != "" ->
        Path.join(System.get_env("CLAUDE_CONFIG_DIR"), ".credentials.json")

      is_binary(System.get_env("HOME")) and System.get_env("HOME") != "" ->
        Path.join([System.get_env("HOME"), ".claude", ".credentials.json"])

      true ->
        nil
    end
  end

  defp token_from_credentials_file(nil), do: {:error, :missing_oauth_token}

  defp token_from_credentials_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, parsed} <- Jason.decode(body),
         %{} = oauth <- Map.get(parsed, "claudeAiOauth"),
         token when is_binary(token) and token != "" <- Map.get(oauth, "accessToken") do
      {:ok, token}
    else
      {:error, :enoent} -> {:error, :missing_oauth_token}
      _ -> {:error, :missing_oauth_token}
    end
  end
end
