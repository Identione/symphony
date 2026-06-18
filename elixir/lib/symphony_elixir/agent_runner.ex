defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with Codex.
  """

  require Logger
  alias SymphonyElixir.{Config, Git, Linear.Issue, Overseer, ProgressSignal, PromptBuilder, Tracker, Workpad, Workspace}
  alias SymphonyElixir.Config.Schema.Overseer, as: OverseerConfig
  alias SymphonyElixir.Overseer.Session, as: OverseerSession

  # Normalized envelope events worth keeping in the overseer transcript window
  # (assistant text / tool calls / turn boundaries across both adapters). Token
  # deltas and lifecycle noise are dropped so the bounded window stays useful.
  @overseer_transcript_events ~w(assistant_message tool_call turn_completed agent_message other_message notification)a

  @type worker_host :: String.t() | nil

  # Reasons the keyless turn cap is reported to Linear (IDE-230).
  @typep capped_reason :: :overseer_disabled | :call_budget_exhausted

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
    {soft_cap, absolute_cap} = turn_ceilings(opts)
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
      # `max_turns` is the keyless fallback ceiling (`agent.max_turns`);
      # `absolute_max_turns` is the hard ceiling the overseer governs up to
      # (`overseer.absolute_max_turns`). They collapse to the same value when
      # the overseer is dormant or a caller pins `opts[:max_turns]` (tests).
      max_turns: soft_cap,
      absolute_max_turns: absolute_cap,
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

  # Resolve the keyless fallback ceiling and the absolute (overseer-governed)
  # ceiling for this run (IDE-230). A caller-pinned `opts[:max_turns]` is a hard
  # bound for both (tests rely on this). Otherwise the soft cap is
  # `agent.max_turns` and the absolute ceiling is `overseer.absolute_max_turns`
  # when the overseer is live, collapsing back to the soft cap when it is not.
  @spec turn_ceilings(keyword()) :: {pos_integer(), pos_integer()}
  defp turn_ceilings(opts) do
    case Keyword.get(opts, :max_turns) do
      pinned when is_integer(pinned) ->
        {pinned, pinned}

      _ ->
        soft_cap = Config.settings!().agent.max_turns

        absolute_cap =
          if Config.overseer_enabled?(), do: Config.overseer().absolute_max_turns, else: soft_cap

        {soft_cap, absolute_cap}
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
    %{adapter: adapter, opts: opts, absolute_max_turns: ceiling, codex_update_recipient: recipient} =
      context

    prompt = build_turn_prompt(issue, opts, turn_number, ceiling, steering)
    settings = Config.settings!()

    handler_opts = [
      verbose_logging: settings.agent.claude.verbose_logging,
      overseer_session: Map.get(context, :overseer_session)
    ]

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
          "workspace=#{context.workspace} turn=#{turn_number}/#{ceiling}"
      )

      handle_turn_continuation(context, app_session, issue, turn_number)
    end
  end

  defp handle_turn_continuation(context, app_session, issue, turn_number) do
    %{issue_state_fetcher: fetcher} = context

    case continue_with_issue?(issue, fetcher) do
      {:continue, refreshed_issue} ->
        govern_continuation(context, app_session, refreshed_issue, turn_number)

      {:done, _refreshed_issue} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Turn-budget governance (IDE-230) ────────────────────────────────────────
  #
  # The single agent session runs turns 1..absolute_max_turns, governed by a
  # cheap per-turn deterministic Layer-1 check plus periodic / loss-triggered
  # Layer-2 (AI overseer) judgement. The legacy `agent.max_turns` cutoff is
  # retired as the active ceiling and survives only as the *keyless fallback*
  # ceiling: when the overseer cannot judge (disabled/unkeyed, call budget
  # exhausted) the run is capped there and a single "could not judge" comment is
  # posted rather than silently auto-extending.
  #
  # Returns the same shape the turn loop threads:
  #   * `do_run_codex_turns(...)` recursion — continue, with optional steering;
  #   * `:max_turns_reached`            — absolute ceiling or keyless cap;
  #   * `{:error, {:overseer_escalation, rationale}}` — hard give-up.
  #
  # The absolute-ceiling and give-up paths run a single bounded graceful
  # wind-down turn (commit + workpad update) before returning their terminal
  # signal; the keyless cap does not (it mirrors the legacy cutoff's teardown).
  @spec govern_continuation(map(), term(), Issue.t(), non_neg_integer()) ::
          :ok | :max_turns_reached | {:error, {:overseer_escalation, String.t()}}
  defp govern_continuation(context, app_session, issue, turn_number) do
    progress = advance_layer1_progress(context, turn_number)

    case budget_decision(context, issue, turn_number, progress) do
      {:continue, steering} ->
        do_run_codex_turns(context, app_session, issue, turn_number + 1, steering)

      {:escalate, rationale} ->
        wind_down(context, app_session, issue, turn_number, "escalation")
        {:error, {:overseer_escalation, rationale}}

      :absolute_ceiling ->
        Logger.info("Reached overseer.absolute_max_turns for #{issue_context(issue)} turn=#{turn_number}; winding down")

        wind_down(context, app_session, issue, turn_number, "absolute-ceiling")
        :max_turns_reached

      {:cap, reason} ->
        Logger.info("Keyless turn cap for #{issue_context(issue)} turn=#{turn_number} reason=#{reason}; returning control to orchestrator")

        post_capped_comment(context, issue, turn_number, reason)
        :max_turns_reached
    end
  end

  # Run the cheap Layer-1 git probe worker-side and roll the run-scoped progress
  # state forward, returning the updated `{fail_streak, assessment}` snapshot.
  # Returns `:unavailable` when the overseer layer is dormant or the probe failed
  # (the streak is left untouched — fail-open). This is independent of the
  # orchestrator's own Layer-1 assessment (which drives the dashboard); this one
  # drives the worker-side budget decision.
  @spec advance_layer1_progress(map(), non_neg_integer()) ::
          OverseerSession.progress_stats() | :unavailable
  defp advance_layer1_progress(%{overseer_session: session} = context, turn_number)
       when is_pid(session) do
    %{workspace: workspace, worker_host: worker_host} = context
    marker = OverseerSession.dispatch_head(session)
    timeout_ms = Config.progress_signal_git_timeout_ms()

    case Git.working_tree_signals(workspace, marker, worker_host, timeout_ms) do
      {:ok, signals} ->
        OverseerSession.capture_dispatch_head(session, signals.head)

        observation = %{
          hash: signals.hash,
          empty: signals.empty,
          commits_since: signals.commits_since,
          # The boundary we reach here is always a normally-completed turn; a
          # terminal error aborts the run before continuation, so there is no
          # per-turn error signature to carry.
          error_sig: nil,
          turn_count: turn_number
        }

        OverseerSession.advance_progress(session, observation, Config.settings!())

      {:error, _reason} ->
        :unavailable
    end
  end

  defp advance_layer1_progress(_context, _turn_number), do: :unavailable

  # Decide what to do at this turn boundary. Precedence:
  #   1. overseer dormant (disabled/unkeyed/failed-start) → keyless ceiling at
  #      `agent.max_turns`;
  #   2. absolute ceiling reached → graceful wind-down then `:max_turns_reached`;
  #   3. streak/cadence trigger fires → consult the overseer (which approves,
  #      gives up, or — out of call budget — falls back to the keyless cap);
  #   4. otherwise march on.
  @spec budget_decision(map(), Issue.t(), non_neg_integer(), OverseerSession.progress_stats() | :unavailable) ::
          {:continue, String.t() | nil} | {:escalate, String.t()} | :absolute_ceiling | {:cap, capped_reason()}
  defp budget_decision(%{overseer_session: session, max_turns: soft_cap, absolute_max_turns: ceiling} = context, issue, turn_number, progress) do
    config = Config.overseer()

    cond do
      not is_pid(session) or not Config.overseer_enabled?() ->
        if turn_number >= soft_cap, do: {:cap, :overseer_disabled}, else: {:continue, nil}

      turn_number >= ceiling ->
        :absolute_ceiling

      should_consult_overseer?(progress, turn_number, config) ->
        consult_overseer(context, issue, turn_number, config)

      true ->
        {:continue, nil}
    end
  end

  # The two consult triggers (IDE-230): a sustained deterministic-fail streak, or
  # the mandatory cadence. Either fires a single Layer-2 consult.
  @spec should_consult_overseer?(
          OverseerSession.progress_stats() | :unavailable,
          non_neg_integer(),
          OverseerConfig.t()
        ) :: boolean()
  defp should_consult_overseer?(progress, turn_number, config) do
    streak_hit? =
      case progress do
        %{fail_streak: streak} when is_integer(streak) -> streak >= config.streak_to_llm
        _ -> false
      end

    cadence = config.mandatory_llm_every
    cadence_hit? = is_integer(cadence) and cadence > 0 and rem(turn_number, cadence) == 0

    streak_hit? or cadence_hit?
  end

  @spec consult_overseer(map(), Issue.t(), non_neg_integer(), OverseerConfig.t()) ::
          {:continue, String.t() | nil} | {:escalate, String.t()} | {:cap, capped_reason()}
  defp consult_overseer(%{overseer_session: session} = context, issue, turn_number, config) do
    %{calls: calls} = OverseerSession.stats(session)

    if calls >= config.max_calls_per_session do
      # The overseer has spent its per-run call budget; for the rest of the run
      # it can no longer judge, so stop extending rather than march on blind.
      {:cap, :call_budget_exhausted}
    else
      # Count the call before running so a crash mid-call still consumes the
      # per-session budget (no infinite re-fire on a flaky engine).
      OverseerSession.register_call(session, turn_number)
      run_overseer_call(context, issue, turn_number, config)
    end
  end

  @spec run_overseer_call(map(), Issue.t(), non_neg_integer(), OverseerConfig.t()) ::
          {:continue, String.t() | nil} | {:escalate, String.t()}
  defp run_overseer_call(%{overseer_session: session} = context, issue, turn_number, config) do
    evidence = assemble_evidence(context, issue, turn_number, config)

    case Overseer.run(evidence, config) do
      {:ok, verdict} ->
        Logger.info(
          "Overseer verdict for #{issue_context(issue)} turn=#{turn_number}/#{config.absolute_max_turns} " <>
            "verdict=#{verdict.verdict} action=#{verdict.recommended_action} confidence=#{verdict.confidence}"
        )

        apply_overseer_action(Overseer.decide_action(verdict, config), session, issue, verdict)

      {:error, reason} ->
        # Fail-open: a transport/parse/timeout error must never disturb the turn
        # loop. The streak is left untouched (only an APPROVE resets it), so a
        # persistent failure keeps re-triggering and the absolute ceiling
        # eventually bounds the run.
        Logger.warning(
          "Overseer call failed for #{issue_context(issue)} turn=#{turn_number}/#{config.absolute_max_turns} " <>
            "(fail-open, continuing): #{inspect(reason)}"
        )

        {:continue, nil}
    end
  end

  # An APPROVE verdict (continue / nudge / recommend_extend_budget, or a
  # confidence-floor / missing-steering downgrade to continue) resets the
  # deterministic-fail streak: the LLM has vouched for the run, so the
  # cheap-signal suspicion is cleared. A give-up verdict (escalate/abort) does
  # not — the caller winds the run down.
  @spec apply_overseer_action(Overseer.action(), pid(), Issue.t(), Overseer.verdict()) ::
          {:continue, String.t() | nil} | {:escalate, String.t()}
  defp apply_overseer_action({:continue, _why}, session, _issue, _verdict) do
    OverseerSession.reset_fail_streak(session)
    {:continue, nil}
  end

  defp apply_overseer_action({:nudge, message}, session, issue, verdict) do
    OverseerSession.reset_fail_streak(session)
    post_overseer_comment(issue, "nudge", verdict.rationale, message, nil)
    {:continue, message}
  end

  defp apply_overseer_action({:recommend_extend_budget, rationale}, session, issue, _verdict) do
    OverseerSession.reset_fail_streak(session)
    post_overseer_comment(issue, "budget-extension recommendation", rationale, nil, nil)
    {:continue, nil}
  end

  defp apply_overseer_action({:escalate, rationale}, _session, issue, verdict) do
    post_overseer_comment(issue, "escalation", rationale, nil, verdict.findings)
    {:escalate, rationale}
  end

  defp apply_overseer_action({:abort, rationale}, _session, issue, verdict) do
    post_overseer_comment(issue, "abort", rationale, nil, verdict.findings)
    {:escalate, rationale}
  end

  # Assemble the read-only evidence bundle. Diff/log/workpad probes are
  # best-effort: a failure drops just that section rather than aborting the
  # classification. The workpad (plan + acceptance criteria) and the Layer-1
  # assessment let the overseer judge progress against the plan.
  @spec assemble_evidence(map(), Issue.t(), non_neg_integer(), OverseerConfig.t()) :: map()
  defp assemble_evidence(%{overseer_session: session, workspace: workspace, worker_host: worker_host}, issue, turn_number, config) do
    %{fail_streak: streak, assessment: assessment} = OverseerSession.progress_stats(session)

    %{
      issue_title: issue.title,
      issue_description: issue.description,
      workpad: fetch_workpad(issue),
      turn: turn_number,
      max_turns: config.absolute_max_turns,
      signals: layer1_signals(assessment, streak),
      git_diff: probe_git_diff(workspace, worker_host, config),
      logs: collect_logs(workspace, config),
      transcript: OverseerSession.transcript(session)
    }
  end

  @spec layer1_signals(ProgressSignal.assessment(), non_neg_integer()) :: map()
  defp layer1_signals(assessment, streak) do
    %{
      layer1_status: assessment.status,
      at_risk_no_commits: assessment.at_risk_no_commits,
      consecutive_fail_streak: streak
    }
  end

  @spec fetch_workpad(Issue.t()) :: String.t() | nil
  defp fetch_workpad(%Issue{id: id}) when is_binary(id) do
    case Workpad.find(id) do
      {:ok, %{body: body}} when is_binary(body) -> body
      _ -> nil
    end
  end

  defp fetch_workpad(_issue), do: nil

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

  # ── Graceful wind-down + keyless cap (IDE-230) ──────────────────────────────

  # One bounded final turn instructing the agent to commit and update its
  # workpad before teardown. Best-effort and cannot rescue the run — the caller
  # returns its terminal signal regardless. Applied only to the worker-side
  # give-up and absolute-ceiling paths; the orchestrator-side deterministic-
  # failure path tears down without this turn (documented asymmetry).
  @spec wind_down(map(), term(), Issue.t(), non_neg_integer(), String.t()) :: :ok
  defp wind_down(%{adapter: adapter, codex_update_recipient: recipient} = context, app_session, issue, turn_number, cause) do
    Logger.info("Overseer wind-down turn for #{issue_context(issue)} turn=#{turn_number} cause=#{cause}")

    settings = Config.settings!()

    handler_opts = [
      verbose_logging: settings.agent.claude.verbose_logging,
      overseer_session: Map.get(context, :overseer_session)
    ]

    _ =
      adapter.run_turn(
        app_session,
        winddown_prompt(),
        issue,
        on_message: compose_message_handler(adapter, recipient, issue, handler_opts),
        turn_timeout_ms: Config.overseer().winddown_timeout_ms
      )

    :ok
  rescue
    exception ->
      Logger.warning("Overseer wind-down turn raised for #{issue_context(issue)} (ignored): #{Exception.message(exception)}")

      :ok
  end

  @spec winddown_prompt() :: String.t()
  defp winddown_prompt do
    """
    Wind-down (FINAL turn):

    - This agent run is being stopped after this turn — no further turns will follow, so do not start new work.
    - Commit any uncommitted progress NOW using the `commit` skill, even if the task is incomplete; partial committed work must not be lost.
    - Update the `## Symphony Workpad` comment with the current status: what is done, what remains, and any blocker a human needs to resolve.
    - Do not begin work you cannot finish and commit within this single turn.
    """
  end

  # The keyless / no-judgement cap comment (IDE-230). Never silent: when the
  # overseer cannot authorize an extension the run is capped and exactly one
  # explanatory comment is posted (the session owns the post-once latch so a
  # flaky decision path cannot double-post within a run).
  @spec post_capped_comment(map(), Issue.t(), non_neg_integer(), capped_reason()) :: :ok
  defp post_capped_comment(%{overseer_session: session}, issue, turn_number, reason) when is_pid(session) do
    if OverseerSession.claim_capped_comment(session) do
      do_post_capped_comment(issue, turn_number, reason)
    end

    :ok
  end

  defp post_capped_comment(_context, issue, turn_number, reason) do
    do_post_capped_comment(issue, turn_number, reason)
  end

  @spec do_post_capped_comment(Issue.t(), non_neg_integer(), capped_reason()) :: :ok
  defp do_post_capped_comment(%Issue{id: issue_id} = issue, turn_number, reason) when is_binary(issue_id) do
    body =
      "🤖 **Overseer (turn-budget cap)**\n\n" <>
        "Reached the keyless turn cap at turn #{turn_number} and did not auto-extend the budget: " <>
        capped_reason_text(reason) <>
        "\n\nThe run is being returned to the orchestrator at `agent.max_turns`. " <>
        "Set `ANTHROPIC_API_KEY` (with `overseer.enabled`) to let the Layer-2 overseer govern extensions up to `overseer.absolute_max_turns`."

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Overseer capped-cutoff comment failed for #{issue_context(issue)}: #{inspect(reason)}")
        :ok
    end
  end

  defp do_post_capped_comment(_issue, _turn_number, _reason), do: :ok

  @spec capped_reason_text(capped_reason()) :: String.t()
  defp capped_reason_text(:overseer_disabled),
    do: "the AI overseer is disabled or unkeyed, so this run could not be judged."

  defp capped_reason_text(:call_budget_exhausted),
    do: "the AI overseer exhausted its per-run call budget (`overseer.max_calls_per_session`), so further turns could not be judged."

  # Single read-only Linear comment carrying the overseer's decision. Best-effort:
  # a failed comment never blocks the turn-loop decision it accompanies.
  @spec post_overseer_comment(Issue.t(), String.t(), String.t(), String.t() | nil, Overseer.findings() | nil) :: :ok
  defp post_overseer_comment(%Issue{id: issue_id} = issue, label, rationale, steering, findings)
       when is_binary(issue_id) do
    body = overseer_comment_body(label, rationale, steering, findings)

    case Tracker.create_comment(issue_id, body) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Overseer comment failed for #{issue_context(issue)}: #{inspect(reason)}")
        :ok
    end
  end

  defp post_overseer_comment(_issue, _label, _rationale, _steering, _findings), do: :ok

  @spec overseer_comment_body(String.t(), String.t(), String.t() | nil, Overseer.findings() | nil) :: String.t()
  defp overseer_comment_body(label, rationale, steering, findings) do
    steering_block =
      case steering do
        msg when is_binary(msg) and msg != "" -> "\n\n**Steering instruction:** #{msg}"
        _ -> ""
      end

    "🤖 **Overseer (#{label})**\n\n#{rationale}#{steering_block}#{findings_block(findings)}"
  end

  # Render the optional human-triage `findings` (escalate/abort only) as a
  # trailing block. A nil/empty findings object renders nothing.
  @spec findings_block(Overseer.findings() | nil) :: String.t()
  defp findings_block(%{summary: summary, blockers: blockers, next_steps_for_human: steps}) do
    [
      findings_summary(summary),
      findings_list("Blockers", blockers),
      findings_list("Next steps for a human", steps)
    ]
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> ""
      parts -> "\n\n---\n\n" <> Enum.join(parts, "\n\n")
    end
  end

  defp findings_block(_findings), do: ""

  @spec findings_summary(String.t() | nil) :: String.t()
  defp findings_summary(summary) when is_binary(summary) and summary != "", do: "**Summary:** #{summary}"
  defp findings_summary(_summary), do: ""

  @spec findings_list(String.t(), [String.t()]) :: String.t()
  defp findings_list(_label, []), do: ""

  defp findings_list(label, items) when is_list(items) do
    "**#{label}:**\n" <> Enum.map_join(items, "\n", fn item -> "- #{item}" end)
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns, _steering) do
    issue
    |> PromptBuilder.build_prompt(opts)
    |> prepend_resume_after_block_directive(Keyword.get(opts, :resume_after_block))
  end

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns, steering) do
    base = """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
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
