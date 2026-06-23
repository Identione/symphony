defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{Config, Git, Linear.Issue, Overseer, PromptBuilder, Tracker, Workpad, Workspace}
  alias SymphonyElixir.Config.Schema.Overseer, as: OverseerConfig
  alias SymphonyElixir.Overseer.Session, as: OverseerSession

  # Normalized envelope events worth keeping in the overseer transcript window
  # (assistant text / tool calls / turn boundaries across both adapters). Token
  # deltas and lifecycle noise are dropped so the bounded window stays useful.
  @overseer_transcript_events ~w(assistant_message tool_call turn_completed agent_message other_message notification)a

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

      # IDE-74: reuse the `{:agent_run_failed, code, reason}` exit shape so
      # the orchestrator's existing `extract_error_code/1` + IDE-73
      # deterministic-failure pipeline pick this up without a new exit tag.
      :max_turns_reached ->
        Logger.info("Agent run hit agent.max_turns for #{issue_context(issue)}; surfacing to orchestrator")

        exit({:agent_run_failed, :max_turns_reached, :max_turns_reached})

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
  # IDE-212: the Layer 2 overseer's escalate/abort verdicts ride the existing
  # `{:agent_run_failed, code, reason}` exit so the deterministic-failure
  # pipeline routes them to the human-review state.
  def classify_error_code({:overseer_escalation, _reason}), do: :overseer_escalation
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
    verbose? = Keyword.get(opts, :verbose_logging, false)
    overseer_session = Keyword.get(opts, :overseer_session)

    base = fn message ->
      record_overseer_envelope(overseer_session, message)
      send_codex_update(recipient, issue, message)
    end

    claude_verbose_handler = fn message ->
      log_claude_event(issue, message)
      base.(message)
    end

    case {adapter, verbose?} do
      {SymphonyElixir.Claude.AppServer, true} -> claude_verbose_handler
      _ -> base
    end
  end

  # Push the envelope into the run-scoped overseer transcript window when the
  # overseer is enabled (the session pid is `nil` otherwise → zero overhead).
  @spec record_overseer_envelope(pid() | nil, map()) :: :ok
  defp record_overseer_envelope(nil, _message), do: :ok

  defp record_overseer_envelope(session, %{event: event} = message)
       when is_pid(session) and event in @overseer_transcript_events do
    OverseerSession.record(session, message)
  end

  defp record_overseer_envelope(_session, _message), do: :ok

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

    overseer_session = maybe_start_overseer_session()

    context = %{
      adapter: adapter,
      workspace: workspace,
      worker_host: worker_host,
      codex_update_recipient: codex_update_recipient,
      opts: opts,
      issue_state_fetcher: issue_state_fetcher,
      max_turns: max_turns,
      overseer_session: overseer_session
    }

    with {:ok, session} <-
           adapter.start_session(workspace, worker_host: worker_host, issue_state: issue.state) do
      try do
        do_run_codex_turns(context, session, issue, 1)
      after
        adapter.stop_session(session)
        stop_overseer_session(overseer_session)
      end
    end
  end

  # Start the run-scoped overseer transcript/cooldown session only when the
  # overseer is enabled+keyed; otherwise `nil` keeps the whole layer dormant.
  @spec maybe_start_overseer_session() :: pid() | nil
  defp maybe_start_overseer_session do
    if Config.overseer_enabled?() do
      case OverseerSession.start_link(Config.overseer().transcript_window) do
        {:ok, pid} ->
          pid

        other ->
          Logger.warning("Overseer session start failed (continuing without overseer): #{inspect(other)}")
          nil
      end
    end
  end

  @spec stop_overseer_session(pid() | nil) :: :ok
  defp stop_overseer_session(nil), do: :ok

  defp stop_overseer_session(pid) when is_pid(pid) do
    if Process.alive?(pid), do: OverseerSession.stop(pid)
    :ok
  end

  defp do_run_codex_turns(context, app_session, issue, turn_number, steering \\ nil) do
    %{adapter: adapter, opts: opts, max_turns: max_turns, codex_update_recipient: recipient} =
      context

    prompt = build_turn_prompt(issue, opts, turn_number, max_turns, steering)
    settings = Config.settings!()

    handler_opts = [
      verbose_logging: settings.agent.claude.verbose_logging,
      overseer_session: Map.get(context, :overseer_session)
    ]

    case adapter.run_turn(
           app_session,
           prompt,
           issue,
           on_message: compose_message_handler(adapter, recipient, issue, handler_opts),
           turn_timeout_ms: Config.active_turn_timeout_ms(settings)
         ) do
      {:ok, turn_session} ->
        Logger.info(
          "Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} " <>
            "workspace=#{context.workspace} turn=#{turn_number}/#{max_turns}"
        )

        handle_turn_continuation(context, app_session, issue, turn_number)

      # IDE-230: the Claude SDK's within-query turn cap (`agent.claude.max_turns`)
      # is a cadence boundary, not a crash. The SDK *returns* a ResultMessage on
      # the breach (`error_max_turns`), so the session is idle and resumable —
      # when the overseer is active we hand the breach to the same
      # continuation/judge path as a clean `turn_end` instead of failing the run
      # and feeding the blind retry loop. `extend_with_overseer` then decides
      # continue/escalate and bounds the extension at `overseer.absolute_max_turns`.
      #
      # Gated on a live overseer on purpose: with no judge to bound it, soft-landing
      # would burn ~max_turns× the compute before a human is looped in, so we let
      # the breach fall through unchanged to the existing IDE-74/IDE-73
      # deterministic-failure path (fast escalation after N consecutive breaches).
      #
      # `:turn_timeout` is deliberately NOT caught here: a wall-clock timeout
      # abandons a turn whose underlying SDK/Codex turn is still running, so
      # resuming the same session would desync the protocol. Turning it into a
      # boundary needs an interrupt-then-drain primitive first (follow-up).
      {:error, {:claude_sdk_error, :max_turns_reached, _msg}} = result ->
        if is_pid(context.overseer_session) do
          Logger.info(
            "Agent run hit agent.claude.max_turns for #{issue_context(issue)} " <>
              "turn=#{turn_number}/#{max_turns}; soft-landing as overseer boundary " <>
              "(session idle, resuming)"
          )

          handle_turn_continuation(context, app_session, issue, turn_number)
        else
          result
        end

      other ->
        other
    end
  end

  defp handle_turn_continuation(context, app_session, issue, turn_number) do
    %{issue_state_fetcher: fetcher} = context

    case continue_with_issue?(issue, fetcher) do
      {:continue, refreshed_issue} ->
        if is_pid(context.overseer_session) do
          extend_with_overseer(context, app_session, refreshed_issue, turn_number)
        else
          legacy_budget_continuation(context, app_session, refreshed_issue, turn_number)
        end

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Keyless / disabled overseer: byte-for-byte the pre-IDE-230 behavior — cap at
  # `agent.max_turns`. When the overseer is *enabled* but dormant (no resolved
  # key), the cap is annotated with a one-shot "could not judge" Linear comment so
  # the missing auto-extend is never silent.
  defp legacy_budget_continuation(context, app_session, issue, turn_number) do
    %{max_turns: max_turns} = context

    if turn_number < max_turns do
      Logger.info(
        "Continuing agent run for #{issue_context(issue)} after normal turn completion " <>
          "turn=#{turn_number}/#{max_turns}"
      )

      do_run_codex_turns(context, app_session, issue, turn_number + 1, nil)
    else
      Logger.info(
        "Reached agent.max_turns for #{issue_context(issue)} with issue still active; " <>
          "returning control to orchestrator"
      )

      maybe_post_dormant_overseer_comment(issue)
      :max_turns_reached
    end
  end

  # ── Layer 2 overseer-gated extension (IDE-212 / IDE-230) ─────────────────────
  #
  # The session extends turn-by-turn up to `overseer.absolute_max_turns`. Each
  # boundary: run the free worker-side deterministic ProgressSignal check (which
  # updates the consecutive fail-streak), then either keep extending or consult
  # the overseer when the streak reached `streak_to_llm` or the turn hits the
  # `mandatory_llm_every` cadence. The overseer approves continued extension or
  # gives up (wind-down + escalate). The absolute ceiling and an exhausted call
  # budget both wind down and stop. Every path is fail-open.
  @typep overseer_outcome ::
           {:approve, String.t() | nil} | {:give_up, String.t()} | {:no_judgement, term()}

  defp extend_with_overseer(context, app_session, issue, turn_number) do
    %{overseer_session: session} = context
    config = Config.overseer()
    settings = Config.settings!()

    observe_progress(context, turn_number, settings)

    %{fail_streak: streak, calls: calls, last_call_turn: last} =
      OverseerSession.progress_snapshot(session)

    # IDE-230 observability: at every continuation turn boundary, emit the
    # decision-bearing counters so the consult/skip/cap branch taken below can be
    # reconstructed from the logs alone.
    log_overseer_turn_boundary(issue, turn_number, streak, calls, last, config)

    cond do
      turn_number >= config.absolute_max_turns ->
        Logger.info(
          "Overseer decision for #{issue_context(issue)} turn=#{turn_number}: winddown " <>
            "reason=absolute_max_turns_reached overseer.absolute_max_turns=#{config.absolute_max_turns}"
        )

        run_winddown_turn(context, app_session, issue, "the absolute turn ceiling (#{config.absolute_max_turns}) was reached")

        :max_turns_reached

      Overseer.should_run?(%{turn: turn_number, calls: calls, last_call_turn: last, fail_streak: streak}, config) ->
        Logger.info(
          "Overseer decision for #{issue_context(issue)} turn=#{turn_number}: consult " <>
            "engine=#{config.engine} reason=#{overseer_trigger_reason(turn_number, streak, config)}"
        )

        # Count the call before running so a crash mid-call still consumes the
        # per-session budget (no infinite re-fire on a flaky engine).
        OverseerSession.register_call(session, turn_number)
        consult_overseer(context, app_session, issue, turn_number, config)

      Overseer.triggered?(turn_number, streak, config) and calls >= config.max_calls_per_session ->
        # A judgement is wanted but the call budget is spent — stop extending
        # rather than run on to the absolute ceiling with no judge.
        Logger.info(
          "Overseer decision for #{issue_context(issue)} turn=#{turn_number}: cap " <>
            "reason=call_budget_exhausted calls=#{calls}/#{config.max_calls_per_session}"
        )

        Logger.warning(
          "Overseer call budget (#{config.max_calls_per_session}) exhausted for " <>
            "#{issue_context(issue)} turn=#{turn_number}; capping run"
        )

        maybe_post_cap_comment(context, issue, "the overseer call budget (#{config.max_calls_per_session}) was exhausted")
        :max_turns_reached

      true ->
        Logger.info(
          "Overseer decision for #{issue_context(issue)} turn=#{turn_number}: skip overseer, extend " <>
            "reason=#{overseer_skip_reason(turn_number, streak, calls, last, config)}"
        )

        do_run_codex_turns(context, app_session, issue, turn_number + 1, nil)
    end
  end

  # One structured line per continuation-turn boundary carrying every counter the
  # consult/skip/cap decision below reads, so an operator can replay the gate
  # logic (IDE-230) from the logs without instrumenting the running daemon.
  @spec log_overseer_turn_boundary(
          Issue.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer() | nil,
          OverseerConfig.t()
        ) :: :ok
  defp log_overseer_turn_boundary(issue, turn_number, streak, calls, last, config) do
    Logger.info(
      "Overseer turn boundary for #{issue_context(issue)} " <>
        "turn=#{turn_number}/#{config.absolute_max_turns} " <>
        "fail_streak=#{streak}/#{config.streak_to_llm} " <>
        "calls=#{calls}/#{config.max_calls_per_session} " <>
        "last_call_turn=#{last_call_turn_for_log(last)} " <>
        "min_turns_between=#{config.min_turns_between} " <>
        "mandatory_llm_every=#{config.mandatory_llm_every} engine=#{config.engine}"
    )

    :ok
  end

  @spec last_call_turn_for_log(non_neg_integer() | nil) :: String.t()
  defp last_call_turn_for_log(nil), do: "none"
  defp last_call_turn_for_log(turn), do: Integer.to_string(turn)

  # Why the overseer *was* consulted: the streak arm, the cadence arm, or both.
  @spec overseer_trigger_reason(non_neg_integer(), non_neg_integer(), OverseerConfig.t()) :: String.t()
  defp overseer_trigger_reason(turn_number, streak, config) do
    streak? = config.streak_to_llm > 0 and streak >= config.streak_to_llm
    cadence? = config.mandatory_llm_every > 0 and rem(turn_number, config.mandatory_llm_every) == 0

    case {streak?, cadence?} do
      {true, true} ->
        "fail_streak=#{streak}>=streak_to_llm=#{config.streak_to_llm} and " <>
          "turn=#{turn_number} on mandatory_llm_every=#{config.mandatory_llm_every} cadence"

      {true, false} ->
        "fail_streak=#{streak}>=streak_to_llm=#{config.streak_to_llm}"

      {false, true} ->
        "turn=#{turn_number} on mandatory_llm_every=#{config.mandatory_llm_every} cadence"

      {false, false} ->
        "triggered"
    end
  end

  # Why the overseer was *not* consulted on a turn that otherwise extends. Mirrors
  # the `Overseer.should_run?/2` gate order so the reason matches the branch the
  # `cond` actually took (not-triggered → cooldown → unsupported engine).
  @spec overseer_skip_reason(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer() | nil,
          OverseerConfig.t()
        ) :: String.t()
  defp overseer_skip_reason(turn_number, streak, _calls, last, config) do
    cond do
      not Overseer.triggered?(turn_number, streak, config) ->
        "not_triggered (fail_streak=#{streak}<streak_to_llm=#{config.streak_to_llm}, " <>
          "turn=#{turn_number} off mandatory_llm_every=#{config.mandatory_llm_every} cadence)"

      is_integer(last) and turn_number - last < config.min_turns_between ->
        "cooldown_active (turn=#{turn_number} - last_call_turn=#{last} < min_turns_between=#{config.min_turns_between})"

      config.engine not in ~w(api sidecar) ->
        "engine_unsupported (engine=#{inspect(config.engine)})"

      true ->
        "no_overseer_gate_matched"
    end
  end

  @spec consult_overseer(map(), term(), Issue.t(), non_neg_integer(), OverseerConfig.t()) ::
          :ok | :max_turns_reached | {:error, {:overseer_escalation, String.t()}} | term()
  defp consult_overseer(context, app_session, issue, turn_number, config) do
    case run_overseer_call(context, issue, turn_number, config) do
      {:approve, steering} ->
        OverseerSession.reset_fail_streak(context.overseer_session)
        do_run_codex_turns(context, app_session, issue, turn_number + 1, steering)

      {:give_up, rationale} ->
        run_winddown_turn(context, app_session, issue, rationale)
        {:error, {:overseer_escalation, rationale}}

      {:no_judgement, _reason} ->
        # No verdict available → never auto-extend past the base budget on a
        # blind guess. Under the base budget, continuing matches today's behavior.
        if turn_number >= context.max_turns do
          maybe_post_cap_comment(context, issue, "the overseer engine returned no judgement")
          :max_turns_reached
        else
          do_run_codex_turns(context, app_session, issue, turn_number + 1, nil)
        end
    end
  end

  # Worker-side Layer-1 ProgressSignal (IDE-230). Reuses the orchestrator's
  # `Git.working_tree_signals/4` probe + `ProgressSignal` core, but holds the
  # rolling state on the run-scoped `OverseerSession`. `error_sig` is `nil`
  # worker-side (terminal errors abort before this boundary), so `:repeated_error`
  # never fires here — `:stuck_state` / `:oscillating` / `at_risk_no_commits`
  # carry the signal. A probe error is fail-open: the streak is left unchanged.
  @spec observe_progress(map(), non_neg_integer(), Config.Schema.t()) :: :ok
  defp observe_progress(%{overseer_session: session, workspace: workspace, worker_host: worker_host}, turn_number, settings) do
    marker = OverseerSession.dispatch_head(session)
    timeout = settings.agent.progress_signal_git_timeout_ms

    case Git.working_tree_signals(workspace, marker, worker_host, timeout) do
      {:ok, signals} ->
        OverseerSession.put_dispatch_head(session, signals.head)

        observation = %{
          hash: signals.hash,
          empty: signals.empty,
          commits_since: signals.commits_since,
          error_sig: nil,
          turn_count: turn_number
        }

        OverseerSession.advance_progress(session, observation, settings)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  @spec run_overseer_call(map(), Issue.t(), non_neg_integer(), OverseerConfig.t()) :: overseer_outcome()
  defp run_overseer_call(context, issue, turn_number, config) do
    evidence = assemble_evidence(context, issue, turn_number, config)

    # `cwd` is consumed only by the `sidecar` engine (the SDK needs a real
    # directory for its tool-less classification turn); the `api` engine ignores
    # it. The issue workspace is already PathSafety-canonical here.
    case Overseer.run(evidence, config, cwd: context.workspace) do
      {:ok, verdict} ->
        action = Overseer.decide_action(verdict, config)

        # `verdict.recommended_action` is what the model asked for; `action` is
        # what the worker will actually do after the confidence-floor / steering /
        # allow_abort downgrades — log both so a downgrade is visible.
        Logger.info(
          "Overseer verdict for #{issue_context(issue)} turn=#{turn_number}/#{config.absolute_max_turns} " <>
            "verdict=#{verdict.verdict} recommended_action=#{verdict.recommended_action} " <>
            "confidence=#{verdict.confidence} resolved_action=#{decided_action_label(action)}"
        )

        apply_overseer_action(action, issue, verdict)

      {:error, reason} ->
        Logger.warning("Overseer call failed for #{issue_context(issue)} turn=#{turn_number} (no judgement): #{inspect(reason)}")

        {:no_judgement, reason}
    end
  end

  # Compact label for the `decide_action/2` result, including the downgrade
  # reason on the `{:continue, why}` arms (e.g. `continue:low_confidence`).
  @spec decided_action_label(Overseer.action()) :: String.t()
  defp decided_action_label({:continue, why}), do: "continue:#{why}"
  defp decided_action_label({:nudge, _msg}), do: "nudge"
  defp decided_action_label({:recommend_extend_budget, _rationale}), do: "recommend_extend_budget"
  defp decided_action_label({:escalate, _rationale, _findings}), do: "escalate"
  defp decided_action_label({:abort, _rationale, _findings}), do: "abort"

  @spec apply_overseer_action(Overseer.action(), Issue.t(), Overseer.verdict()) :: overseer_outcome()
  defp apply_overseer_action({:continue, _why}, _issue, _verdict), do: {:approve, nil}

  defp apply_overseer_action({:nudge, message}, issue, verdict) do
    post_overseer_comment(issue, "nudge", verdict.rationale, message)
    {:approve, message}
  end

  defp apply_overseer_action({:recommend_extend_budget, rationale}, issue, _verdict) do
    post_overseer_comment(issue, "budget extension approved", rationale, nil)
    {:approve, nil}
  end

  defp apply_overseer_action({:escalate, rationale, findings}, issue, _verdict) do
    post_overseer_giveup_comment(issue, "escalation", rationale, findings)
    {:give_up, rationale}
  end

  defp apply_overseer_action({:abort, rationale, findings}, issue, _verdict) do
    post_overseer_giveup_comment(issue, "abort", rationale, findings)
    {:give_up, rationale}
  end

  # Assemble the read-only evidence bundle. Workpad/diff/log probes are
  # best-effort: a failure drops just that section rather than aborting the
  # classification. The workpad (plan + acceptance criteria) and the worker-side
  # deterministic assessment are fed so the overseer judges progress vs. the plan.
  @spec assemble_evidence(map(), Issue.t(), non_neg_integer(), OverseerConfig.t()) :: map()
  defp assemble_evidence(%{overseer_session: session, workspace: workspace, worker_host: worker_host}, issue, turn_number, config) do
    %{
      issue_title: issue.title,
      issue_description: issue.description,
      workpad: probe_workpad(issue, config.input_byte_limit),
      turn: turn_number,
      max_turns: config.absolute_max_turns,
      signals: signals_evidence(session),
      git_diff: probe_git_diff(workspace, worker_host, config),
      logs: collect_logs(workspace, config),
      transcript: OverseerSession.transcript(session)
    }
  end

  @spec probe_workpad(Issue.t(), non_neg_integer()) :: String.t() | nil
  defp probe_workpad(%Issue{id: id}, limit) when is_binary(id) do
    case Workpad.text(id) do
      text when is_binary(text) -> String.slice(text, 0, limit)
      _ -> nil
    end
  end

  defp probe_workpad(_issue, _limit), do: nil

  @spec signals_evidence(pid()) :: map()
  defp signals_evidence(session) do
    %{assessment: assessment, fail_streak: streak} = OverseerSession.progress_snapshot(session)

    %{
      status: assessment.status,
      at_risk_no_commits: assessment.at_risk_no_commits,
      deterministic_fail_streak: streak
    }
  end

  @spec probe_git_diff(String.t(), worker_host(), map()) :: String.t() | nil
  defp probe_git_diff(workspace, worker_host, config) do
    case Git.diff_summary(workspace, worker_host, config.input_byte_limit) do
      {:ok, diff} -> diff
      {:error, _reason} -> nil
    end
  end

  # Read the tails of build/test logs matching `config.log_globs`. Local-only:
  # the diff already proves the worker_host case is covered by the transcript,
  # and these globs resolve against the local workspace path. A read error on
  # any single file is dropped silently (best-effort evidence).
  @spec collect_logs(String.t(), map()) :: [{String.t(), String.t()}]
  defp collect_logs(workspace, config) when is_binary(workspace) do
    config.log_globs
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(workspace, glob)) end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn path -> {Path.relative_to(path, workspace), read_log_tail(path, config.input_byte_limit)} end)
    |> Enum.reject(fn {_name, tail} -> tail in [nil, ""] end)
  end

  @spec read_log_tail(String.t(), non_neg_integer()) :: String.t() | nil
  defp read_log_tail(path, byte_limit) do
    case File.read(path) do
      {:ok, content} -> tail_bytes(content, byte_limit)
      {:error, _reason} -> nil
    end
  end

  # Keep the last `byte_limit` bytes, then drop any partial leading codepoint so
  # the tail is always valid UTF-8 for the prompt.
  @spec tail_bytes(binary(), non_neg_integer()) :: String.t()
  defp tail_bytes(content, byte_limit) when byte_size(content) <= byte_limit, do: content

  defp tail_bytes(content, byte_limit) do
    content
    |> binary_part(byte_size(content) - byte_limit, byte_limit)
    |> trim_invalid_leading()
  end

  @spec trim_invalid_leading(binary()) :: String.t()
  defp trim_invalid_leading(<<>>), do: ""

  defp trim_invalid_leading(binary) do
    if String.valid?(binary) do
      binary
    else
      <<_dropped, rest::binary>> = binary
      trim_invalid_leading(rest)
    end
  end

  # Single read-only Linear comment carrying the overseer's decision. Best-effort:
  # a failed comment never blocks the turn-loop decision it accompanies.
  @spec post_overseer_comment(Issue.t(), String.t(), String.t(), String.t() | nil) :: :ok
  defp post_overseer_comment(%Issue{id: issue_id} = issue, label, rationale, steering)
       when is_binary(issue_id) do
    body = overseer_comment_body(label, rationale, steering)

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Overseer comment failed for #{issue_context(issue)}: #{inspect(reason)}")
        :ok
    end
  rescue
    # Comment posting is strictly best-effort: a tracker that raises must never
    # break the turn-loop decision it accompanies.
    exception ->
      Logger.warning("Overseer comment raised for #{issue_context(issue)}: #{Exception.message(exception)}")
      :ok
  end

  defp post_overseer_comment(_issue, _label, _rationale, _steering), do: :ok

  @spec overseer_comment_body(String.t(), String.t(), String.t() | nil) :: String.t()
  defp overseer_comment_body(label, rationale, steering) do
    steering_block =
      case steering do
        msg when is_binary(msg) and msg != "" -> "\n\n**Steering instruction:** #{msg}"
        _ -> ""
      end

    "🤖 **Overseer (#{label})**\n\n#{rationale}#{steering_block}"
  end

  # Give-up comment (IDE-230): the overseer's rationale plus its structured
  # findings (why no more progress is expected, blockers, next steps for a human).
  @spec post_overseer_giveup_comment(Issue.t(), String.t(), String.t(), map() | nil) :: :ok
  defp post_overseer_giveup_comment(issue, label, rationale, findings) do
    post_overseer_comment(issue, label, rationale <> render_findings(findings), nil)
  end

  @spec render_findings(map() | nil) :: String.t()
  defp render_findings(findings) when is_map(findings) do
    sections =
      [
        findings_text("Summary", Map.get(findings, "summary")),
        findings_bullets("Blockers", Map.get(findings, "blockers")),
        findings_bullets("Next steps for a human", Map.get(findings, "next_steps_for_human"))
      ]
      |> Enum.reject(&is_nil/1)

    case sections do
      [] -> ""
      parts -> "\n\n### Findings\n\n" <> Enum.join(parts, "\n\n")
    end
  end

  defp render_findings(_findings), do: ""

  @spec findings_text(String.t(), term()) :: String.t() | nil
  defp findings_text(label, value) when is_binary(value) and value != "", do: "**#{label}:** #{value}"
  defp findings_text(_label, _value), do: nil

  @spec findings_bullets(String.t(), term()) :: String.t() | nil
  defp findings_bullets(label, list) when is_list(list) and list != [] do
    case list |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.map_join("\n", &"- #{&1}") do
      "" -> nil
      bullets -> "**#{label}:**\n#{bullets}"
    end
  end

  defp findings_bullets(_label, _list), do: nil

  # One-shot "could not judge" cap comment (IDE-230) for the enabled+keyed path
  # when the run is stopped without a fresh verdict (engine error at the base
  # budget, or an exhausted call budget). Idempotent via the run-scoped session.
  @spec maybe_post_cap_comment(map(), Issue.t(), String.t()) :: :ok
  defp maybe_post_cap_comment(%{overseer_session: session}, issue, reason) when is_pid(session) do
    if OverseerSession.claim_capped_comment(session) do
      post_overseer_comment(
        issue,
        "capped — overseer could not judge",
        "The run was capped at the current turn because #{reason}.",
        nil
      )
    end

    :ok
  end

  # Dormant-overseer cap comment (IDE-230): the overseer is enabled but has no
  # resolved key (or unsupported engine), so the run capped at `agent.max_turns`
  # with no auto-extend. Posted once at the cap turn so it is never silent. When
  # the overseer is fully disabled (`enabled: false`) the operator opted out, so
  # nothing is posted.
  @spec maybe_post_dormant_overseer_comment(Issue.t()) :: :ok
  defp maybe_post_dormant_overseer_comment(issue) do
    ov = Config.overseer()

    if ov.enabled and not Config.overseer_enabled?() do
      post_overseer_comment(
        issue,
        "capped — overseer could not judge",
        "The run was capped at `agent.max_turns` (no auto-extend) because the overseer " <>
          "could not render a judgement: #{dormant_reason(ov)}.",
        nil
      )
    end

    :ok
  end

  @spec dormant_reason(OverseerConfig.t()) :: String.t()
  defp dormant_reason(ov) do
    cond do
      not is_binary(ov.api_key) or ov.api_key == "" -> "no `ANTHROPIC_API_KEY` resolved"
      ov.engine != "api" -> "engine #{inspect(ov.engine)} is not implemented"
      true -> "the overseer is dormant"
    end
  end

  # The single graceful wind-down turn (IDE-230): before the session is torn down
  # and the issue moves to Human Review, the agent gets one bounded turn to commit
  # what it deems worth keeping and update its workpad. It cannot re-enter the
  # loop or rescue the run — the result is discarded and control falls through to
  # the escalation/`:max_turns_reached` return.
  @spec run_winddown_turn(map(), term(), Issue.t(), String.t()) :: :ok
  defp run_winddown_turn(context, app_session, issue, reason) do
    %{adapter: adapter, codex_update_recipient: recipient, overseer_session: session} = context
    settings = Config.settings!()

    Logger.info("Running wind-down turn for #{issue_context(issue)} before escalation: #{reason}")

    handler_opts = [
      verbose_logging: settings.agent.claude.verbose_logging,
      overseer_session: session
    ]

    try do
      adapter.run_turn(app_session, winddown_prompt(reason), issue,
        on_message: compose_message_handler(adapter, recipient, issue, handler_opts),
        turn_timeout_ms: Config.overseer().winddown_timeout_ms
      )
    rescue
      exception ->
        Logger.warning("Wind-down turn raised for #{issue_context(issue)}: #{Exception.message(exception)}")
    end

    :ok
  end

  defp winddown_prompt(reason) do
    """
    ## Final wind-down turn (IMPORTANT)

    Symphony is handing this issue to a human (moving it to the Human Review state) because #{reason}.

    This is your FINAL turn. Do NOT start new work. Use it only to:

    - Commit any work worth keeping using the `commit` skill (partial progress is fine — committed beats lost).
    - Update the `## Symphony Workpad` comment with the current status: what is done, what remains, and any blockers a human needs to know.

    Once you have committed and updated the workpad, end the turn.
    """
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, _steering) do
    issue
    |> PromptBuilder.build_prompt(opts)
    |> prepend_resume_after_block_directive(Keyword.get(opts, :resume_after_block))
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, steering) do
    base = """
    Continuation guidance:

    - The previous #{Config.agent_label()} turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """

    k = Config.budget_pressure_turns()
    turns_left = max_turns - turn_number

    base
    |> maybe_append_budget_pressure(turns_left, k)
    |> append_overseer_steering_directive(steering)
  end

  defp maybe_append_budget_pressure(base, turns_left, k) do
    if turns_left > 0 and turns_left <= k,
      do: append_budget_pressure_directive(base, turns_left),
      else: base
  end

  # Layer 2 steering slot (IDE-212): when the overseer returned a `nudge`, its
  # `steering_message` rides the *next* turn's prompt as an explicit directive.
  # `@doc false` public seam mirroring `append_budget_pressure_directive/2`.
  @doc false
  @spec append_overseer_steering_directive(String.t(), String.t() | nil) :: String.t()
  def append_overseer_steering_directive(prompt, steering)
      when is_binary(prompt) and is_binary(steering) and steering != "" do
    prompt <> "\n\n" <> overseer_steering_directive(steering)
  end

  def append_overseer_steering_directive(prompt, _steering) when is_binary(prompt), do: prompt

  defp overseer_steering_directive(steering) do
    """
    ## Overseer steering (IMPORTANT)

    An automated overseer reviewed this run's progress and produced one concrete instruction. Act on it now:

    #{steering}
    """
  end

  # Budget-pressure steering (IDE-189 / Layer 0). When the orchestrator's
  # continuation march is within `agent.budget_pressure_turns` of the
  # `agent.max_turns` cap, the *next* turn's prompt carries an explicit
  # directive to commit the working state now, so converging work is captured
  # before the cap forcibly stops the run. The prompt is atomic once sent, so
  # the directive must ride a turn the agent can still act on — `turns_left > 0`
  # guarantees we never append on the useless final turn.
  #
  # This is a `@doc false` public seam mirroring
  # `prepend_resume_after_block_directive/2`: Layer 2 reuses it (and may add
  # sibling `append_*_directive/2` functions following the same shape) so the
  # continuation branch becomes a small append/prepend composition pipeline
  # without re-touching the threshold logic above.
  @doc false
  @spec append_budget_pressure_directive(String.t(), non_neg_integer()) :: String.t()
  def append_budget_pressure_directive(prompt, turns_left)
      when is_binary(prompt) and is_integer(turns_left) and turns_left > 0 do
    prompt <> "\n\n" <> budget_pressure_directive(turns_left)
  end

  def append_budget_pressure_directive(prompt, _turns_left) when is_binary(prompt), do: prompt

  defp budget_pressure_directive(turns_left) do
    turn_word = if turns_left == 1, do: "turn", else: "turns"

    """
    Budget-pressure guidance (IMPORTANT):

    - You have only #{turns_left} continuation #{turn_word} left before this run is forcibly stopped.
    - Commit your current working state NOW using the `commit` skill, even if incomplete — partial committed progress beats losing uncommitted work at the cap.
    - Do not start work you cannot finish AND commit in the remaining #{turn_word}.
    - If everything is already committed, continue normally.
    """
  end

  # Prepend a rebase-on-resume directive when the orchestrator re-dispatches a
  # session that was previously paused on a dependency blocker (§4.1.8). The
  # blocker has since landed on the base branch, so the resuming agent must
  # integrate the updated base before continuing the ticket work. `@doc false`
  # public seam so the coverage suite can assert the directive shape without
  # standing up a real session.
  @doc false
  @spec prepend_resume_after_block_directive(String.t(), map() | nil) :: String.t()
  def prepend_resume_after_block_directive(prompt, %{} = resume_after_block) when is_binary(prompt) do
    resume_after_block_directive(resume_after_block) <> "\n\n" <> prompt
  end

  def prepend_resume_after_block_directive(prompt, _resume_after_block) when is_binary(prompt), do: prompt

  defp resume_after_block_directive(resume_after_block) do
    """
    Rebase-on-resume guidance:

    - This session was previously paused because it was blocked by another issue.#{landed_blocker_clause(resume_after_block)}
    - Before resuming the ticket work, integrate the latest base branch into this workspace so your changes build on top of the landed work. Use the `pull` skill (fetch the base branch and rebase/merge it in), resolving any conflicts.
    - Only after the workspace is up to date with the landed base should you continue the remaining ticket work.
    """
  end

  defp landed_blocker_clause(%{blockers: [_ | _] = blockers}) do
    " The blocking issue(s) #{Enum.join(blockers, ", ")} this work depended on have now landed on the base branch."
  end

  defp landed_blocker_clause(_resume_after_block) do
    " The issue that blocked it has now landed on the base branch."
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

      # IDE-211: a transient Linear rate-limit on the *post-turn* state refresh
      # must not discard a turn that already completed (and typically committed)
      # successfully. Treating it as a fatal failure exits the run and triggers a
      # full fresh-session retry, throwing away the finished turn's work and
      # tokens. Instead, treat it as done-for-now: the orchestrator's reconcile
      # loop re-dispatches the issue once the rate-limit window clears, if it is
      # still active. If the agent already moved the issue to a terminal state,
      # nothing re-runs at all.
      {:error, :rate_limited} ->
        Logger.warning(
          "Issue-state refresh rate-limited after a completed turn for #{issue_context(issue)}; " <>
            "treating run as done — reconcile will re-dispatch if still active"
        )

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
