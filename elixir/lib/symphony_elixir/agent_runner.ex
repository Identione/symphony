defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @log_value_limit 256

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    # The orchestrator owns host retries so one worker lifetime never hops machines.
    worker_host = selected_worker_host(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} ->
        # The adapter's session_id (Codex thread-turn pair / Claude SDK
        # session_id) is held inside the adapter session struct returned to
        # `do_run_codex_turns`, but failed runs lose that handle before they
        # bubble up here. Emit the IDE-75 fallback so log parsers always see
        # a `session_id=` field.
        Logger.error("Agent run failed for #{issue_context(issue)} session_id=unknown: #{inspect(reason)}")
        # Carry the classified `error_code` (IDE-71 taxonomy) through the
        # process exit so the orchestrator's :DOWN handler can branch on it
        # without re-parsing `inspect(reason)`. The previous `raise
        # RuntimeError` collapsed every failure into an opaque
        # `{%RuntimeError{}, stacktrace}` exit reason.
        exit({:agent_run_failed, classify_error_code(reason), reason})
    end
  end

  @doc false
  @spec classify_error_code(term()) :: atom()
  def classify_error_code({:turn_failed, code, _params}) when is_atom(code), do: code
  def classify_error_code({:codex_error_notification, code, _payload}) when is_atom(code), do: code
  def classify_error_code({:claude_sdk_error, code, _msg}) when is_atom(code), do: code
  def classify_error_code(:turn_timeout), do: :turn_timeout
  def classify_error_code(:response_timeout), do: :response_timeout
  def classify_error_code({:port_exit, _status}), do: :port_exit
  def classify_error_code({:claude_sidecar_exit, _status}), do: :claude_sidecar_exit
  def classify_error_code(_reason), do: :unknown

  @doc """
  Best-effort `Retry-After` hint (ms) extracted from a classified failure
  reason. IDE-72 retry policy consumes this when the upstream error carries
  an explicit hint (Codex puts the value in `params.error.headers`/
  `params.error.retry_after`; Claude only carries rendered exception text,
  so we fall back to a bounded regex over `inspect/2` of the payload). Returns
  `nil` when no hint is present or the value isn't a positive integer.
  """
  @spec extract_retry_after_ms(term()) :: pos_integer() | nil
  def extract_retry_after_ms({tag, _code, body})
      when tag in [:claude_sdk_error, :turn_failed, :codex_error_notification],
      do: parse_retry_after(body)

  def extract_retry_after_ms(_other), do: nil

  defp parse_retry_after(payload) when is_map(payload) do
    parse_retry_after_from_map(payload) ||
      parse_retry_after(inspect(payload, limit: 50, printable_limit: 512))
  end

  defp parse_retry_after(text) when is_binary(text) do
    case Regex.run(~r/retry[\s_-]?after[^\d]{0,8}(\d+)/i, text) do
      [_match, seconds] ->
        case Integer.parse(seconds) do
          {n, _} when n > 0 -> n * 1_000
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_retry_after(_other), do: nil

  defp parse_retry_after_from_map(%{"error" => %{"headers" => headers}}) when is_map(headers) do
    headers
    |> Enum.find_value(fn {k, v} ->
      if is_binary(k) and String.downcase(k) == "retry-after", do: v
    end)
    |> retry_after_value_to_ms()
  end

  defp parse_retry_after_from_map(%{"retry_after" => value}), do: retry_after_value_to_ms(value)
  defp parse_retry_after_from_map(%{"retryAfter" => value}), do: retry_after_value_to_ms(value)

  defp parse_retry_after_from_map(%{"error" => %{"retry_after" => value}}),
    do: retry_after_value_to_ms(value)

  defp parse_retry_after_from_map(_payload), do: nil

  defp retry_after_value_to_ms(value) when is_integer(value) and value > 0, do: value * 1_000

  defp retry_after_value_to_ms(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} when n > 0 -> n * 1_000
      _ -> nil
    end
  end

  defp retry_after_value_to_ms(_value), do: nil

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace)

        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `@doc false` so the handler-shape test can drive it without going through
  # `adapter.run_turn/4` (which would also need a real session).
  #
  # `:verbose_logging` (default `false`) gates the high-volume per-envelope
  # Claude log lines (`tool_call`/`assistant_message`/`turn_completed`/
  # `permission_request`/`system_init`/forwarded `claude_cli` stderr). When
  # `false`, the handler still forwards events to the dashboard recipient but
  # emits no log lines — keeping `make start` quiet under
  # `agent.claude.verbose_logging=false`. Per-issue/per-session lifecycle
  # logging in `AgentRunner` and `Claude.AppServer` stays at info either way.
  @doc false
  @spec compose_message_handler(module(), pid() | nil, Issue.t(), keyword()) :: (map() -> :ok)
  def compose_message_handler(adapter, recipient, issue, opts \\ []) do
    base = fn message -> send_codex_update(recipient, issue, message) end
    verbose? = Keyword.get(opts, :verbose_logging, false)

    claude_verbose_handler = fn message ->
      log_claude_event(issue, message)
      base.(message)
    end

    case {adapter, verbose?} do
      {SymphonyElixir.Claude.AppServer, true} -> claude_verbose_handler
      _ -> base
    end
  end

  @doc false
  @spec log_claude_event(Issue.t(), map()) :: :ok
  def log_claude_event(issue, %{event: type, payload: payload} = msg) do
    sid = Map.get(msg, :session_id)
    ctx = "#{issue_context(issue)}#{session_context(sid)}"
    log_claude_event_line(type, ctx, payload)
    :ok
  end

  def log_claude_event(_issue, _other), do: :ok

  defp session_context(sid) when is_binary(sid), do: " session_id=#{sid}"
  defp session_context(_), do: ""

  # `Logger.info(fn -> … end)` defers message construction so the per-envelope
  # path costs nothing when the level filters them out.

  defp log_claude_event_line(:tool_call, ctx, payload) do
    Logger.info(fn ->
      "claude tool_call for #{ctx} name=#{Map.get(payload, :name)} input=#{fold(Map.get(payload, :input))}"
    end)
  end

  defp log_claude_event_line(:assistant_message, ctx, payload) do
    Logger.info(fn ->
      ~s(claude assistant_message for #{ctx} text=#{fold_quote(Map.get(payload, :text))})
    end)
  end

  defp log_claude_event_line(:turn_completed, ctx, payload) do
    Logger.info(fn ->
      usage = Map.get(payload, :usage, %{}) || %{}

      "claude turn_completed for #{ctx} stop_reason=#{Map.get(payload, :stop_reason)} " <>
        "num_turns=#{Map.get(payload, :num_turns)} " <>
        "usage.input_tokens=#{Map.get(usage, :input_tokens)} " <>
        "usage.output_tokens=#{Map.get(usage, :output_tokens)}"
    end)
  end

  defp log_claude_event_line(:permission_request, ctx, payload) do
    Logger.info(fn ->
      "claude permission_request for #{ctx} request=#{fold(Map.get(payload, :request))}"
    end)
  end

  defp log_claude_event_line(:system_init, ctx, _payload) do
    Logger.info("claude system_init for #{ctx}")
  end

  defp log_claude_event_line(:log, _ctx, payload) do
    src = Map.get(payload, :source) || "sidecar"
    Logger.info("#{src}: #{Map.get(payload, :message)}")
  end

  defp log_claude_event_line(_other, _ctx, _payload), do: :ok

  defp fold(nil), do: ""
  defp fold(value) when is_binary(value), do: cap(value, @log_value_limit)

  defp fold(value) do
    case Jason.encode(value) do
      {:ok, json} -> cap(json, @log_value_limit)
      _ -> cap(inspect(value, limit: 50, printable_limit: @log_value_limit), @log_value_limit)
    end
  end

  defp fold_quote(nil), do: ~s("")
  defp fold_quote(value) when is_binary(value), do: ~s("#{cap(value, @log_value_limit)}")
  defp fold_quote(value), do: ~s("#{cap(inspect(value), @log_value_limit)}")

  # `byte_size` short-circuits the common short-string path without paying
  # for grapheme counting (`String.length` is O(n)). Truncation still uses
  # graphemes so we never split a multi-byte codepoint mid-character.
  defp cap(string, limit) when is_binary(string) do
    if byte_size(string) <= limit do
      string
    else
      length = String.length(string)

      if length <= limit do
        string
      else
        truncated = String.slice(string, 0, limit)
        "#{truncated}…(#{length - limit} more chars)"
      end
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(recipient, %Issue{id: issue_id}, worker_host, workspace)
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace), do: :ok

  defp run_codex_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)
    adapter = Keyword.get(opts, :adapter, Config.adapter_module())

    Logger.info("Selected coding-agent adapter for #{issue_context(issue)}: #{inspect(adapter)}")

    context = %{
      adapter: adapter,
      workspace: workspace,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns
    }

    with {:ok, session} <- adapter.start_session(workspace, worker_host: worker_host) do
      try do
        do_run_codex_turns(context, session, issue, 1)
      after
        adapter.stop_session(session)
      end
    end
  end

  defp do_run_codex_turns(context, app_session, issue, turn_number) do
    %{adapter: adapter, opts: opts, max_turns: max_turns, codex_update_recipient: recipient} =
      context

    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)
    settings = Config.settings!()

    handler_opts = [verbose_logging: settings.agent.claude.verbose_logging]

    with {:ok, turn_session} <-
           adapter.run_turn(
             app_session,
             prompt,
             issue,
             on_message: compose_message_handler(adapter, recipient, issue, handler_opts),
             turn_timeout_ms: Config.active_turn_timeout_ms(settings)
           ) do
      Logger.info(
        "Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} " <>
          "workspace=#{context.workspace} turn=#{turn_number}/#{max_turns}"
      )

      handle_turn_continuation(context, app_session, issue, turn_number)
    end
  end

  defp handle_turn_continuation(context, app_session, issue, turn_number) do
    %{issue_state_fetcher: fetcher, max_turns: max_turns} = context

    case continue_with_issue?(issue, fetcher) do
      {:continue, refreshed_issue} when turn_number < max_turns ->
        Logger.info(
          "Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion " <>
            "turn=#{turn_number}/#{max_turns}"
        )

        do_run_codex_turns(context, app_session, refreshed_issue, turn_number + 1)

      {:continue, refreshed_issue} ->
        Logger.info(
          "Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; " <>
            "returning control to orchestrator"
        )

        :ok

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  # `@doc false` public seam so the coverage suite can exercise the
  # host-selection branches (preferred vs. first-configured vs. none)
  # directly, without standing up a real SSH workspace per branch.
  @doc false
  @spec selected_worker_host(worker_host(), [String.t()]) :: worker_host()
  def selected_worker_host(nil, []), do: nil

  def selected_worker_host(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" -> host
      _ when hosts == [] -> nil
      _ -> List.first(hosts)
    end
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
