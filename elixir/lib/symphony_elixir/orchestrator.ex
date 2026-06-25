defmodule SymphonyElixir.Orchestrator do
  @moduledoc """
  Polls Linear and dispatches repository copies to Codex-backed workers.
  """

  use GenServer
  require Logger
  import Bitwise, only: [<<<: 2]

  alias SymphonyElixir.{
    AgentRunner,
    Config,
    DeterministicFailure,
    Git,
    ProgressSignal,
    ProviderQuota,
    StatusDashboard,
    Tracker,
    Workspace
  }

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.{RetryPolicy, SessionBudget}

  @continuation_retry_delay_ms 1_000
  @failure_retry_base_ms 10_000
  # Slightly above the dashboard render interval so "checking now…" can render.
  @poll_transition_render_delay_ms 20
  # Caps bound Linear API usage when crawling transitive blockers.
  @graph_expansion_max_rounds 3
  @graph_max_nodes 200
  # When every sub-issue of a parent/umbrella issue is Done, the parent is moved
  # to this state (see complete_parents_with_all_children_done/2). Mirrors the
  # per-parent `children(first: N)` fetch cap in Linear.Client (@child_page_size):
  # a parent whose child list is at the cap may be truncated, so we don't
  # auto-complete it.
  @parent_done_state "Done"
  @subissue_child_cap 50
  @empty_codex_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    seconds_running: 0
  }

  # Claude billing has two extra cache fields. `total_tokens` keeps codex parity
  # — `input + output` only, never folded with the cache fields. SPEC §10.8.
  @empty_claude_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
    seconds_running: 0
  }

  defmodule State do
    @moduledoc """
    Runtime state for the orchestrator polling loop.
    """

    defstruct [
      :poll_interval_ms,
      :max_concurrent_agents,
      :next_poll_due_at_ms,
      :poll_check_in_progress,
      :tick_timer_ref,
      :tick_token,
      running: %{},
      completed: MapSet.new(),
      claimed: MapSet.new(),
      blocked: %{},
      dependency_blocked: %{},
      # Issues that were paused mid-run because they gained a non-terminal
      # blocker (§4.1.8). Keyed by Linear issue id; each value is
      # `%{blockers: [%{identifier, pr_url}]}` recording the blockers that held
      # the work, each carrying its merged GitHub PR URL when Linear has it.
      # When the issue is re-dispatched (its blockers having landed), the entry
      # is consumed to inject a rebase-on-resume directive into the turn-1
      # prompt so the session integrates the now-landed base before continuing.
      # Entries are cleared on dispatch; an issue that is paused then abandoned
      # before re-dispatch leaves a small, harmless residual entry until restart.
      rebase_pending: %{},
      dependency_graph: %{},
      retry_attempts: %{},
      # Per-issue counter of consecutive same-code adapter failures, used to
      # surface stuck issues to Linear after N alerts and escalate them to a
      # non-active state after M (IDE-73). Keyed by Linear issue id; entries
      # follow `t:SymphonyElixir.DeterministicFailure.entry/0`.
      deterministic_failures: %{},
      # In-flight DeterministicFailure escalations (IDE-102). Keyed by issue id;
      # each value is a `t:pending_escalation/0` carrying the data we need to
      # apply the result when the task messages back. The issue is held in
      # `claimed` while pending so the polling loop won't re-dispatch it, but
      # is NOT in `running` (the agent has exited) and has no retry timer
      # scheduled yet — the result handler decides whether to schedule one.
      pending_escalations: %{},
      # Cumulative, episode-scoped per-issue session counter backing the
      # `agent.max_sessions_per_issue` cap (P1/R1(a)). Keyed by issue id →
      # `%{generation, count}`. Mirrored to `session_budget_table` (DETS) on
      # every change so it survives a daemon restart / `make upgrade`.
      session_counts: %{},
      # DETS handle for the durable mirror, or `nil` when persistence is off
      # (no instance `run/` dir wired) — the in-memory counter still caps within
      # a single daemon lifetime.
      session_budget_table: nil,
      codex_totals: nil,
      claude_totals: nil,
      provider_quotas: %{}
    ]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    now_ms = System.monotonic_time(:millisecond)
    config = Config.settings!()

    {session_budget_table, session_counts} =
      SessionBudget.open(Application.get_env(:symphony_elixir, :session_budget_file))

    state = %State{
      poll_interval_ms: config.polling.interval_ms,
      max_concurrent_agents: config.agent.max_concurrent_agents,
      next_poll_due_at_ms: now_ms,
      poll_check_in_progress: false,
      tick_timer_ref: nil,
      tick_token: nil,
      session_counts: session_counts,
      session_budget_table: session_budget_table,
      codex_totals: @empty_codex_totals,
      claude_totals: @empty_claude_totals,
      provider_quotas: %{codex: nil, claude: nil}
    }

    run_terminal_workspace_cleanup()

    # The initial tick fires a poll cycle whose reconcile clears running/claimed
    # entries absent from the tracker's current view. Tests that seed orchestrator
    # state *after* start_link (via :sys.replace_state) and then drive a specific
    # event need to opt out of that auto-poll so it can't race and wipe the seed
    # (IDE-131). Production always polls on start.
    state =
      if Keyword.get(opts, :poll_on_start, true) do
        schedule_tick(state, 0)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_info({:tick, tick_token}, %{tick_token: tick_token} = state)
      when is_reference(tick_token) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info({:tick, _tick_token}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state = %{
      state
      | poll_check_in_progress: true,
        next_poll_due_at_ms: nil,
        tick_timer_ref: nil,
        tick_token: nil
    }

    notify_dashboard()
    :ok = schedule_poll_cycle_start()
    {:noreply, state}
  end

  def handle_info(:run_poll_cycle, state) do
    state = refresh_runtime_config(state)
    state = maybe_dispatch(state)
    state = schedule_tick(state, state.poll_interval_ms)
    state = %{state | poll_check_in_progress: false}

    notify_dashboard()
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{running: running} = state
      ) do
    case find_issue_id_for_ref(running, ref) do
      nil ->
        {:noreply, state}

      issue_id ->
        {running_entry, state} = pop_running_entry(state, issue_id)
        state = record_session_completion_totals(state, running_entry)
        session_id = running_entry_session_id(running_entry)
        identifier = running_entry_identifier(running_entry, issue_id)

        state = handle_agent_down(reason, state, issue_id, running_entry, session_id)

        Logger.info("Agent task finished for issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} reason=#{inspect(reason)}")

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:worker_runtime_info, issue_id, runtime_info}, %{running: running} = state)
      when is_binary(issue_id) and is_map(runtime_info) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        updated_running_entry =
          running_entry
          |> maybe_put_runtime_value(:worker_host, runtime_info[:worker_host])
          |> maybe_put_runtime_value(:workspace_path, runtime_info[:workspace_path])

        notify_dashboard()
        {:noreply, %{state | running: Map.put(running, issue_id, updated_running_entry)}}
    end
  end

  def handle_info(
        {:codex_worker_update, issue_id, %{event: _, timestamp: _} = update},
        %{running: running} = state
      ) do
    case Map.get(running, issue_id) do
      nil ->
        {:noreply, state}

      running_entry ->
        state = handle_worker_update(state, running, issue_id, running_entry, update)

        notify_dashboard()
        {:noreply, state}
    end
  end

  def handle_info({:codex_worker_update, _issue_id, _update}, state), do: {:noreply, state}

  def handle_info({:provider_quota_snapshot, provider, snapshot}, state)
      when provider in [:codex, :claude] and is_map(snapshot) do
    provider_quotas =
      state.provider_quotas
      |> ensure_provider_quotas()
      |> Map.put(provider, snapshot)

    notify_dashboard()
    {:noreply, %{state | provider_quotas: provider_quotas}}
  end

  def handle_info({:retry_issue, issue_id, retry_token}, state) do
    result =
      case pop_retry_attempt_state(state, issue_id, retry_token) do
        {:ok, attempt, metadata, state} -> handle_retry_issue(state, issue_id, attempt, metadata)
        :missing -> {:noreply, state}
      end

    notify_dashboard()
    result
  end

  def handle_info({:retry_issue, _issue_id}, state), do: {:noreply, state}

  # The token guards against stale results — a reconcile path can wipe
  # `pending_escalations[issue_id]` while the task is in flight, and the
  # task's eventual message must then no-op rather than re-apply state.
  def handle_info({:deterministic_failure_result, issue_id, token, action, result}, state) do
    case Map.get(state.pending_escalations, issue_id) do
      %{token: ^token} = pending ->
        state = %{state | pending_escalations: Map.delete(state.pending_escalations, issue_id)}
        state = apply_deterministic_failure_result(state, issue_id, pending, action, result)
        notify_dashboard()
        {:noreply, state}

      _ ->
        Logger.debug("Ignoring stale deterministic_failure_result for issue_id=#{issue_id} action=#{inspect(action)}")

        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    Logger.debug("Orchestrator ignored message: #{inspect(msg)}")
    {:noreply, state}
  end

  defp handle_agent_down(:normal, state, issue_id, running_entry, session_id) do
    settings = Config.settings!()

    cond do
      input_required_blocker?(running_entry) ->
        block_input_required_agent_down(state, issue_id, running_entry, session_id, :normal)

      session_budget_exhausted?(state, issue_id, settings) ->
        # The issue keeps finishing turns cleanly yet never leaves the active
        # set (poll-only / blocked-parent loop). Stop the continuation march and
        # escalate through the same DeterministicFailure machinery as IDE-73.
        escalate_session_budget(state, issue_id, running_entry, session_id, settings)

      true ->
        Logger.info("Agent task completed for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}; scheduling active-state continuation check")

        state
        |> clear_deterministic_failure(issue_id)
        |> complete_issue(issue_id)
        |> schedule_issue_retry(issue_id, 1, %{
          identifier: running_entry.identifier,
          issue_url: running_entry.issue.url,
          session_id: session_id,
          delay_type: :continuation,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        })
    end
  end

  defp handle_agent_down(reason, state, issue_id, running_entry, session_id) do
    # IDE-189: the `:max_turns_reached` cutoff does not pass through
    # `terminate_running_issue`. The task has already finished by the time this
    # `:DOWN` arrives and the workspace persists for the 1s-cadence retry, so
    # snapshot the converging work to a durable WIP ref before the fresh session
    # (or a later operator) resumes on the same — still dirty — tree.
    #
    # IDE-230: an `:overseer_escalation` is about to move the issue to Human
    # Review and clean up the workspace — snapshot here too so a wind-down turn
    # that failed to commit still leaves a durable WIP ref behind.
    if extract_error_code(reason) in [:max_turns_reached, :overseer_escalation] do
      identifier = running_entry_identifier(running_entry, issue_id)
      maybe_preserve_uncommitted_work(running_entry, issue_id, identifier, :max_turns)
    end

    if input_required_blocker?(running_entry) do
      block_input_required_agent_down(state, issue_id, running_entry, session_id, reason)
    else
      state
      |> maybe_track_deterministic_failure(issue_id, running_entry, reason)
      |> case do
        # Side effect handed off to a supervised task; scheduling a retry
        # here would race with the result handler's own retry decision.
        {:pending, next_state} ->
          next_state

        {:continue, next_state} ->
          retry_agent_down(next_state, issue_id, running_entry, session_id, reason)
      end
    end
  end

  defp block_input_required_agent_down(state, issue_id, running_entry, session_id, reason) do
    error = blocker_error(running_entry, "agent exited: #{inspect(reason)}")

    Logger.warning("Agent task blocked for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id}: #{error}")

    state
    |> clear_deterministic_failure(issue_id)
    |> block_issue_from_entry(issue_id, running_entry, error)
  end

  defp retry_agent_down(state, issue_id, running_entry, session_id, reason) do
    error_code = extract_error_code(reason) || :unknown
    retry_after_ms = AgentRunner.extract_retry_after_ms(extract_inner_reason(reason))
    next_attempt = next_retry_attempt_from_running(running_entry) || 1

    case RetryPolicy.decide(error_code, next_attempt, retry_after_ms, Config.settings!()) do
      :no_retry ->
        block_for_no_retry(state, issue_id, running_entry, session_id, reason, error_code)

      {:retry, delay_ms} ->
        Logger.warning(
          "Agent task exited for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} session_id=#{session_id} reason=#{inspect(reason)} " <>
            "error_code=#{error_code}; scheduling retry in #{delay_ms}ms (attempt #{next_attempt})"
        )

        schedule_issue_retry(state, issue_id, next_attempt, %{
          identifier: running_entry.identifier,
          issue_url: running_entry.issue.url,
          session_id: session_id,
          error: "agent exited: #{inspect(reason)} (#{error_code})",
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path),
          delay_ms_override: delay_ms
        })
    end
  end

  defp block_for_no_retry(state, issue_id, running_entry, session_id, reason, error_code) do
    error = "no retry for #{error_code}: #{inspect(reason)}"

    Logger.warning(
      "Agent task halted for issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} " <>
        "session_id=#{session_id} error_code=#{error_code}: #{error}"
    )

    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  # `reason` here is the process exit reason from the `:DOWN` handler. When
  # `AgentRunner.run/3` fails it `exit/1`s with `{:agent_run_failed, code,
  # inner_reason}` so the structured taxonomy survives the supervisor hop.
  # Anything else (raw atoms, `:killed`, etc.) bypasses the deterministic-
  # failure counter — those come from kill paths inside the orchestrator
  # itself or from tests synthesising abnormal exits, and shouldn't be treated
  # as classified upstream failures.
  defp maybe_track_deterministic_failure(state, issue_id, running_entry, reason) do
    case extract_error_code(reason) do
      nil ->
        {:continue, clear_deterministic_failure(state, issue_id)}

      code ->
        settings = Config.settings!()
        prev_entry = Map.get(state.deterministic_failures, issue_id)

        case DeterministicFailure.decide(prev_entry, code, settings) do
          {:drop, :no_action} ->
            {:continue, clear_deterministic_failure(state, issue_id)}

          {updated_entry, action} ->
            apply_deterministic_action(
              state,
              issue_id,
              running_entry,
              reason,
              updated_entry,
              action,
              settings
            )
        end
    end
  end

  defp apply_deterministic_action(
         state,
         issue_id,
         _running_entry,
         _reason,
         entry,
         :no_action,
         _settings
       ) do
    {:continue, put_deterministic_failure(state, issue_id, entry)}
  end

  # The Tracker round-trips inside `DeterministicFailure.handle/3` (workpad
  # fetch, comment update/create, state move) can block for up to
  # `agent.max_retry_backoff_ms` (5 min default). Run them under
  # `SymphonyElixir.TaskSupervisor` so the orchestrator's main loop stays free
  # to handle other issues' `:DOWN`/dispatch/poll messages while they're in
  # flight. We persist the incremented counter immediately, but the
  # `notified_*` flags and the escalation state-drop are deferred to the
  # result handler so the IDE-73 retry contract (flags only set on success)
  # is preserved.
  defp apply_deterministic_action(state, issue_id, running_entry, reason, entry, action, settings) do
    issue = Map.get(running_entry, :issue) || running_entry_issue_fallback(running_entry, issue_id)
    session_id = running_entry_session_id(running_entry)

    case spawn_deterministic_action(issue_id, issue, action, settings) do
      {:ok, token} ->
        pending = %{
          token: token,
          action: action,
          entry: entry,
          running_entry: running_entry,
          reason: reason
        }

        {:pending,
         state
         |> put_deterministic_failure(issue_id, entry)
         |> put_pending_escalation(issue_id, pending)}

      {:error, spawn_reason} ->
        # Spawning the side effect failed (e.g. Task.Supervisor at
        # `max_children`). Persist the counter increment and fall through to
        # the existing retry path so the next same-code :DOWN re-tries the
        # alert/escalate side effect via `decide/3`.
        Logger.warning("DeterministicFailure spawn failed for #{inspect(action)} issue_id=#{issue_id}: #{inspect(spawn_reason)}")

        {:continue,
         retry_agent_down(
           put_deterministic_failure(state, issue_id, entry),
           issue_id,
           running_entry,
           session_id,
           reason
         )}
    end
  end

  defp spawn_deterministic_action(issue_id, issue, action, settings) do
    recipient = self()
    token = make_ref()

    spawn_result =
      Task.Supervisor.start_child(deterministic_action_task_supervisor(), fn ->
        result =
          try do
            DeterministicFailure.handle(action, issue, settings)
          catch
            kind, caught_reason ->
              {:error, {:task_crashed, kind, caught_reason, __STACKTRACE__}}
          end

        send(recipient, {:deterministic_failure_result, issue_id, token, action, result})
      end)

    case spawn_result do
      {:ok, _pid} -> {:ok, token}
      {:error, _} = err -> err
    end
  end

  # Test seam: defaults to the real `SymphonyElixir.TaskSupervisor` but can be
  # overridden so tests can point the deterministic-action spawn at a capped
  # `Task.Supervisor` and exercise the `{:error, :max_children}` fallback.
  defp deterministic_action_task_supervisor do
    Application.get_env(:symphony_elixir, :deterministic_action_task_supervisor, SymphonyElixir.TaskSupervisor)
  end

  # Test seam mirroring `deterministic_action_task_supervisor/0`: defaults to
  # the real supervisor but is overridable so the agent-dispatch spawn-failure
  # retry path can be exercised against a capped `Task.Supervisor`.
  defp agent_task_supervisor do
    Application.get_env(:symphony_elixir, :agent_task_supervisor, SymphonyElixir.TaskSupervisor)
  end

  defp apply_deterministic_failure_result(state, issue_id, pending, action, result) do
    %{entry: entry, running_entry: running_entry, reason: reason} = pending
    session_id = running_entry_session_id(running_entry)

    case {action, result} do
      {{:escalate, _, _}, {:ok, :escalated}} ->
        # `escalate_running_issue/3` resets the counter (issue is leaving the
        # active set), so any flag write here would be immediately discarded.
        escalate_running_issue(state, issue_id, running_entry)

      {{:alert, _, _}, :ok} ->
        state
        |> put_deterministic_failure(issue_id, %{entry | notified_alert?: true})
        |> retry_agent_down(issue_id, running_entry, session_id, reason)

      {_action, _other} ->
        # :alert that errored, or :escalate where the comment post or state
        # move failed. Notification flags stay clear so the next same-code
        # failure re-fires the same action via `decide/3` (IDE-73 retry
        # contract); the issue still needs a retry scheduled.
        state
        |> put_deterministic_failure(issue_id, entry)
        |> retry_agent_down(issue_id, running_entry, session_id, reason)
    end
  end

  # When DeterministicFailure successfully escalates an issue, the polling
  # loop must stop re-dispatching it. Drop the bookkeeping mirroring what
  # `release_issue_claim/2` does, but without re-scheduling a retry. We also
  # cancel any in-flight retry timer; the issue now lives in the escalation
  # state and `reconcile_running_issues` would otherwise still see it queued.
  defp escalate_running_issue(state, issue_id, running_entry) do
    cancel_retry_timer(state, issue_id)
    cleanup_issue_workspace(Map.get(running_entry, :identifier), Map.get(running_entry, :worker_host))

    %{
      state
      | running: Map.delete(state.running, issue_id),
        claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        deterministic_failures: DeterministicFailure.reset(state.deterministic_failures, issue_id),
        pending_escalations: Map.delete(state.pending_escalations, issue_id)
    }
    |> close_session_episode(issue_id)
  end

  defp put_pending_escalation(state, issue_id, pending) do
    %{state | pending_escalations: Map.put(state.pending_escalations, issue_id, pending)}
  end

  defp cancel_retry_timer(state, issue_id) do
    case Map.get(state.retry_attempts, issue_id) do
      %{timer_ref: timer_ref} when is_reference(timer_ref) ->
        Process.cancel_timer(timer_ref)
        :ok

      _ ->
        :ok
    end
  end

  defp put_deterministic_failure(state, issue_id, entry) do
    %{state | deterministic_failures: Map.put(state.deterministic_failures, issue_id, entry)}
  end

  defp clear_deterministic_failure(state, issue_id) do
    %{state | deterministic_failures: DeterministicFailure.reset(state.deterministic_failures, issue_id)}
  end

  # ── Cumulative per-issue session cap (P1/R1(a)) ─────────────────────────────

  defp session_count(%State{session_counts: counts}, issue_id) do
    case Map.get(counts, issue_id) do
      %{count: count} when is_integer(count) -> count
      _ -> 0
    end
  end

  defp session_budget_exhausted?(%State{} = state, issue_id, settings) do
    cap = settings.agent.max_sessions_per_issue
    is_integer(cap) and cap > 0 and session_count(state, issue_id) >= cap
  end

  # Bump the current episode's session count and mirror it to DETS. Called on
  # every actual session launch (initial dispatch and every relaunch), so the
  # count reflects total sessions run in the active episode.
  defp bump_session_count(%State{} = state, issue_id) do
    entry = Map.get(state.session_counts, issue_id, %{generation: 1, count: 0})
    updated = %{entry | count: entry.count + 1}
    SessionBudget.put(state.session_budget_table, issue_id, updated)
    %{state | session_counts: Map.put(state.session_counts, issue_id, updated)}
  end

  # The issue is leaving the active set (terminal, escalated, or otherwise
  # released). Advance the generation and zero the count so a later re-entry
  # (e.g. a human moving an escalated issue back to Todo) starts a fresh
  # episode with full budget instead of re-escalating off the stale tally.
  defp close_session_episode(%State{} = state, issue_id) do
    case Map.get(state.session_counts, issue_id) do
      nil ->
        state

      %{generation: generation} ->
        updated = %{generation: generation + 1, count: 0}
        SessionBudget.put(state.session_budget_table, issue_id, updated)
        %{state | session_counts: Map.put(state.session_counts, issue_id, updated)}
    end
  end

  # Escalate via the same supervised DeterministicFailure side-effect path the
  # :DOWN handler uses (workpad comment + state move), then drop the issue from
  # the active set in the result handler. The synthetic entry keeps the shared
  # `apply_deterministic_failure_result/5` fallback (escalation side-effect
  # failed) well-formed.
  defp escalate_session_budget(%State{} = state, issue_id, running_entry, session_id, settings) do
    count = session_count(state, issue_id)
    action = {:escalate, :max_sessions_per_issue, count}
    issue = Map.get(running_entry, :issue) || running_entry_issue_fallback(running_entry, issue_id)

    Logger.warning(
      "Issue hit cumulative session cap issue_id=#{issue_id} issue_identifier=#{running_entry.identifier} " <>
        "session_id=#{session_id} sessions=#{count} cap=#{settings.agent.max_sessions_per_issue}; escalating"
    )

    entry = %{
      code: :max_sessions_per_issue,
      count: count,
      notified_alert?: false,
      notified_escalation?: false
    }

    case spawn_deterministic_action(issue_id, issue, action, settings) do
      {:ok, token} ->
        pending = %{
          token: token,
          action: action,
          entry: entry,
          running_entry: running_entry,
          reason: {:agent_run_failed, :max_sessions_per_issue, :session_cap}
        }

        put_pending_escalation(state, issue_id, pending)

      {:error, spawn_reason} ->
        # Couldn't spawn the side effect; fall back to a continuation retry so
        # the issue isn't stranded. The next clean exit re-checks the cap.
        Logger.warning("Session-cap escalation spawn failed for issue_id=#{issue_id}: #{inspect(spawn_reason)}")

        state
        |> complete_issue(issue_id)
        |> schedule_issue_retry(issue_id, 1, %{
          identifier: running_entry.identifier,
          issue_url: running_entry.issue.url,
          session_id: session_id,
          delay_type: :continuation,
          worker_host: Map.get(running_entry, :worker_host),
          workspace_path: Map.get(running_entry, :workspace_path)
        })
    end
  end

  defp extract_error_code({:agent_run_failed, code, _reason}) when is_atom(code), do: code
  defp extract_error_code(_reason), do: nil

  defp extract_inner_reason({:agent_run_failed, _code, inner}), do: inner
  defp extract_inner_reason(reason), do: reason

  defp running_entry_issue_fallback(running_entry, issue_id) do
    %Issue{
      id: issue_id,
      identifier: Map.get(running_entry, :identifier) || issue_id,
      title: "",
      state: ""
    }
  end

  defp maybe_dispatch(%State{} = state) do
    state =
      state
      |> reconcile_running_issues()
      |> reconcile_blocked_issues()

    with :ok <- Config.validate!(),
         {:ok, issues} <- Tracker.fetch_candidate_issues() do
      state =
        state
        |> complete_parents_with_all_children_done(issues)
        |> refresh_dependency_blocked(issues)
        |> refresh_dependency_graph(issues)

      if available_slots(state) > 0, do: choose_issues(issues, state), else: state
    else
      {:error, :missing_linear_api_token} ->
        Logger.error("Linear API token missing in WORKFLOW.md")
        state

      {:error, :missing_linear_project_slug} ->
        Logger.error("Linear project slug missing in WORKFLOW.md")
        state

      {:error, :missing_tracker_kind} ->
        Logger.error("Tracker kind missing in WORKFLOW.md")

        state

      {:error, {:unsupported_tracker_kind, kind}} ->
        Logger.error("Unsupported tracker kind in WORKFLOW.md: #{inspect(kind)}")

        state

      {:error, {:invalid_workflow_config, message}} ->
        Logger.error("Invalid WORKFLOW.md config: #{message}")
        state

      {:error, {:claude_remote_worker_unsupported, hosts}} ->
        Logger.error(
          "agent.kind: claude is incompatible with worker.ssh_hosts=#{inspect(hosts)}; " <>
            "the Claude adapter has no remote-worker support. Either remove worker.ssh_hosts " <>
            "or switch agent.kind to codex."
        )

        state

      {:error, :claude_dontask_denies_all_tools} ->
        Logger.error(
          "agent.claude permission_mode: dontAsk with no allowed_tools denies every tool; " <>
            "list allowed_tools (whitelist) or set permission_mode: bypassPermissions (allow-all)."
        )

        state

      {:error, {:missing_workflow_file, path, reason}} ->
        Logger.error("Missing WORKFLOW.md at #{path}: #{inspect(reason)}")
        state

      {:error, :workflow_front_matter_not_a_map} ->
        Logger.error("Failed to parse WORKFLOW.md: workflow front matter must decode to a map")
        state

      {:error, {:workflow_parse_error, reason}} ->
        Logger.error("Failed to parse WORKFLOW.md: #{inspect(reason)}")
        state

      {:error, :rate_limited} ->
        Logger.debug("Skipping Linear poll cycle; rate-limit window active")
        state

      {:error, reason} ->
        Logger.error("Failed to fetch from Linear: #{inspect(reason)}")
        state
    end
  end

  defp reconcile_running_issues(%State{} = state) do
    state = reconcile_stalled_running_issues(state)
    running_ids = Map.keys(state.running)

    if running_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(running_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_running_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_running_issue_ids(running_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh running issue states: #{inspect(reason)}; keeping active workers")

          state
      end
    end
  end

  defp reconcile_blocked_issues(%State{} = state) do
    blocked_ids = Map.keys(state.blocked)

    if blocked_ids == [] do
      state
    else
      case Tracker.fetch_issue_states_by_ids(blocked_ids) do
        {:ok, issues} ->
          issues
          |> reconcile_blocked_issue_states(
            state,
            active_state_set(),
            terminal_state_set()
          )
          |> reconcile_missing_blocked_issue_ids(blocked_ids, issues)

        {:error, reason} ->
          Logger.debug("Failed to refresh blocked issue states: #{inspect(reason)}; keeping blocked issues")

          state
      end
    end
  end

  @doc false
  @spec reconcile_issue_states_for_test([Issue.t()], term()) :: term()
  def reconcile_issue_states_for_test(issues, %State{} = state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  def reconcile_issue_states_for_test(issues, state) when is_list(issues) do
    reconcile_running_issue_states(issues, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec complete_parents_with_all_children_done_for_test([Issue.t()], term()) :: term()
  def complete_parents_with_all_children_done_for_test(issues, %State{} = state)
      when is_list(issues) do
    complete_parents_with_all_children_done(state, issues)
  end

  @doc false
  @spec should_dispatch_issue_for_test(Issue.t(), term()) :: boolean()
  def should_dispatch_issue_for_test(%Issue{} = issue, %State{} = state) do
    should_dispatch_issue?(issue, state, active_state_set(), terminal_state_set())
  end

  @doc false
  @spec revalidate_issue_for_dispatch_for_test(Issue.t(), ([String.t()] -> term())) ::
          {:ok, Issue.t()} | {:skip, Issue.t() | :missing} | {:error, term()}
  def revalidate_issue_for_dispatch_for_test(%Issue{} = issue, issue_fetcher)
      when is_function(issue_fetcher, 1) do
    revalidate_issue_for_dispatch(issue, issue_fetcher, terminal_state_set())
  end

  @doc false
  @spec sort_issues_for_dispatch_for_test([Issue.t()]) :: [Issue.t()]
  def sort_issues_for_dispatch_for_test(issues) when is_list(issues) do
    sort_issues_for_dispatch(issues)
  end

  @doc false
  @spec select_worker_host_for_test(term(), String.t() | nil) :: String.t() | nil | :no_worker_capacity
  def select_worker_host_for_test(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host)
  end

  defp reconcile_running_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_running_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_running_issue_states(
      rest,
      reconcile_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, true, :terminal)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :non_routed)

      issue_blocked_by_non_terminal?(issue, terminal_states) ->
        pause_dependency_blocked_running_issue(state, issue, active_states)

      active_issue_state?(issue.state, active_states) ->
        refresh_running_issue_state(state, issue)

      true ->
        Logger.info("Issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; stopping active agent")

        terminate_running_issue(state, issue.id, false, :non_active)
    end
  end

  defp reconcile_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([], state, _active_states, _terminal_states), do: state

  defp reconcile_blocked_issue_states([issue | rest], state, active_states, terminal_states) do
    reconcile_blocked_issue_states(
      rest,
      reconcile_blocked_issue_state(issue, state, active_states, terminal_states),
      active_states,
      terminal_states
    )
  end

  defp reconcile_blocked_issue_state(%Issue{} = issue, state, active_states, terminal_states) do
    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Blocked issue moved to terminal state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        cleanup_issue_workspace(issue.identifier, blocked_issue_worker_host(state, issue.id))
        release_issue_claim(state, issue.id)

      !issue_routable_to_worker?(issue) ->
        Logger.info("Blocked issue no longer routed to this worker: #{issue_context(issue)} assignee=#{inspect(issue.assignee_id)}; releasing block")
        release_issue_claim(state, issue.id)

      active_issue_state?(issue.state, active_states) ->
        refresh_blocked_issue_state(state, issue)

      true ->
        Logger.info("Blocked issue moved to non-active state: #{issue_context(issue)} state=#{issue.state}; releasing block")
        release_issue_claim(state, issue.id)
    end
  end

  defp reconcile_blocked_issue_state(_issue, state, _active_states, _terminal_states), do: state

  defp reconcile_missing_running_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        log_missing_running_issue(state_acc, issue_id)
        terminate_running_issue(state_acc, issue_id, false, :not_visible)
      end
    end)
  end

  defp reconcile_missing_running_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp reconcile_missing_blocked_issue_ids(%State{} = state, requested_issue_ids, issues)
       when is_list(requested_issue_ids) and is_list(issues) do
    visible_issue_ids =
      issues
      |> Enum.flat_map(fn
        %Issue{id: issue_id} when is_binary(issue_id) -> [issue_id]
        _ -> []
      end)
      |> MapSet.new()

    Enum.reduce(requested_issue_ids, state, fn issue_id, state_acc ->
      if MapSet.member?(visible_issue_ids, issue_id) do
        state_acc
      else
        Logger.info("Blocked issue no longer visible during state refresh: issue_id=#{issue_id}; releasing block")
        release_issue_claim(state_acc, issue_id)
      end
    end)
  end

  defp reconcile_missing_blocked_issue_ids(state, _requested_issue_ids, _issues), do: state

  defp log_missing_running_issue(%State{} = state, issue_id) when is_binary(issue_id) do
    case Map.get(state.running, issue_id) do
      %{identifier: identifier} ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id} issue_identifier=#{identifier}; stopping active agent")

      _ ->
        Logger.info("Issue no longer visible during running-state refresh: issue_id=#{issue_id}; stopping active agent")
    end
  end

  defp log_missing_running_issue(_state, _issue_id), do: :ok

  defp refresh_running_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.running, issue.id) do
      %{issue: _} = running_entry ->
        %{state | running: Map.put(state.running, issue.id, %{running_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp pause_dependency_blocked_running_issue(%State{} = state, %Issue{} = issue, active_states) do
    state =
      state
      |> maybe_restore_dependency_blocked_issue_state(issue, active_states)
      |> mark_rebase_pending(issue)

    Logger.info("Issue is waiting on non-terminal blockers: #{issue_context(issue)} state=#{inspect(issue.state)} blocked_by=#{length(issue.blocked_by)}; pausing active agent")

    terminate_running_issue(state, issue.id, false, :dependency_pause)
  end

  # Record that this paused session must rebase onto its (now-soon-to-land)
  # blockers' work before it resumes. `terminate_running_issue/3` with
  # `cleanup_workspace: false` preserves the workspace and leaves
  # `rebase_pending` intact, so the entry survives until the next dispatch.
  defp mark_rebase_pending(%State{} = state, %Issue{id: issue_id} = issue) when is_binary(issue_id) do
    %{state | rebase_pending: Map.put(state.rebase_pending, issue_id, %{blockers: blocker_refs(issue)})}
  end

  defp mark_rebase_pending(%State{} = state, _issue), do: state

  # Blocker refs carried into `rebase_pending` as `%{identifier, pr_url}` maps so
  # the resume directive can name the blocker *and* point at its merged PR. The
  # PR URL is best-effort (`nil` until Linear links the PR attachment).
  defp blocker_refs(%Issue{blocked_by: blockers}) when is_list(blockers) do
    blockers
    |> Enum.flat_map(fn
      %{identifier: identifier} = ref when is_binary(identifier) ->
        [%{identifier: identifier, pr_url: Map.get(ref, :pr_url)}]

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp blocker_refs(_issue), do: []

  defp maybe_restore_dependency_blocked_issue_state(%State{} = state, %Issue{} = issue, active_states) do
    if active_issue_state?(issue.state, active_states) do
      state
    else
      state
      |> dependency_resume_state(issue, active_states)
      |> restore_dependency_blocked_issue_state(state, issue)
    end
  end

  defp restore_dependency_blocked_issue_state(nil, %State{} = state, %Issue{} = issue) do
    Logger.warning("Dependency-blocked issue is outside active states and no active resume state is configured: #{issue_context(issue)} state=#{inspect(issue.state)}")
    state
  end

  defp restore_dependency_blocked_issue_state(state_name, %State{} = state, %Issue{} = issue) do
    case Tracker.update_issue_state(issue.id, state_name) do
      :ok ->
        Logger.info("Moved dependency-blocked issue back to active state: #{issue_context(issue)} from=#{inspect(issue.state)} to=#{inspect(state_name)}")
        state

      {:error, reason} ->
        Logger.warning("Failed to move dependency-blocked issue back to active state: #{issue_context(issue)} from=#{inspect(issue.state)} to=#{inspect(state_name)} reason=#{inspect(reason)}")
        state
    end
  end

  defp dependency_resume_state(%State{} = state, %Issue{} = issue, active_states) do
    state.running
    |> Map.get(issue.id, %{})
    |> Map.get(:issue)
    |> case do
      %Issue{state: previous_state} when is_binary(previous_state) ->
        if active_issue_state?(previous_state, active_states),
          do: previous_state,
          else: default_dependency_resume_state()

      _ ->
        default_dependency_resume_state()
    end
  end

  defp default_dependency_resume_state do
    active_states = Config.settings!().tracker.active_states

    Enum.find(active_states, &match_normalized_state?(&1, "todo")) || List.first(active_states)
  end

  defp refresh_blocked_issue_state(%State{} = state, %Issue{} = issue) do
    case Map.get(state.blocked, issue.id) do
      %{issue: _} = blocked_entry ->
        %{state | blocked: Map.put(state.blocked, issue.id, %{blocked_entry | issue: issue})}

      _ ->
        state
    end
  end

  defp terminate_running_issue(%State{} = state, issue_id, cleanup_workspace, cutoff_reason) do
    case Map.get(state.running, issue_id) do
      nil ->
        release_issue_claim(state, issue_id)

      %{pid: pid, ref: ref, identifier: identifier} = running_entry ->
        state = record_session_completion_totals(state, running_entry)
        worker_host = Map.get(running_entry, :worker_host)

        # Non-destructive cutoff (IDE-189): snapshot any uncommitted work before
        # the workspace can be reclaimed or the task stopped. Runs even when
        # `cleanup_workspace` is false (the Backlog/non-active regression: the
        # agent was stopped but its work was never committed).
        maybe_preserve_uncommitted_work(running_entry, issue_id, identifier, cutoff_reason)

        if cleanup_workspace do
          cleanup_issue_workspace(identifier, worker_host)
        end

        stop_running_task(pid, ref)

        %{
          state
          | running: Map.delete(state.running, issue_id),
            claimed: MapSet.delete(state.claimed, issue_id),
            blocked: Map.delete(state.blocked, issue_id),
            retry_attempts: Map.delete(state.retry_attempts, issue_id),
            deterministic_failures: DeterministicFailure.reset(state.deterministic_failures, issue_id),
            pending_escalations: Map.delete(state.pending_escalations, issue_id)
        }
        |> close_session_episode(issue_id)

      _ ->
        release_issue_claim(state, issue_id)
    end
  end

  defp reconcile_stalled_running_issues(%State{} = state) do
    settings = Config.settings!()
    idle_timeout_ms = Config.active_stall_timeout_ms(settings)
    tool_timeout_ms = Config.active_tool_stall_timeout_ms(settings)

    cond do
      idle_timeout_ms <= 0 ->
        state

      map_size(state.running) == 0 ->
        state

      true ->
        now = DateTime.utc_now()

        Enum.reduce(state.running, state, fn {issue_id, running_entry}, state_acc ->
          timeout_ms = stall_timeout_for_entry(running_entry, idle_timeout_ms, tool_timeout_ms)
          maybe_restart_stalled_issue(state_acc, issue_id, running_entry, now, timeout_ms)
        end)
    end
  end

  # A native tool call (e.g. a long `Bash` build) is silent to Symphony while it
  # runs, so the tight idle window would misread it as a hang. When one is in
  # flight, fall back to the longer tool-stall window (never shorter than idle).
  defp stall_timeout_for_entry(running_entry, idle_timeout_ms, tool_timeout_ms) do
    if Map.get(running_entry, :claude_tools_in_flight, 0) > 0 do
      max(idle_timeout_ms, tool_timeout_ms)
    else
      idle_timeout_ms
    end
  end

  defp maybe_restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    if Map.has_key?(state.blocked, issue_id) do
      state
    else
      restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms)
    end
  end

  defp restart_stalled_issue(state, issue_id, running_entry, now, timeout_ms) do
    elapsed_ms = stall_elapsed_ms(running_entry, now)

    if is_integer(elapsed_ms) and elapsed_ms > timeout_ms do
      identifier = Map.get(running_entry, :identifier, issue_id)
      session_id = running_entry_session_id(running_entry)

      if input_required_blocker?(running_entry) do
        error = blocker_error(running_entry, "stalled for #{elapsed_ms}ms after Codex requested operator input")

        Logger.warning("Issue blocked: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; #{error}")

        state
        |> record_session_completion_totals(running_entry)
        |> stop_and_block_issue(issue_id, running_entry, error)
      else
        Logger.warning("Issue stalled: issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} elapsed_ms=#{elapsed_ms}; restarting with backoff")

        next_attempt = next_retry_attempt_from_running(running_entry)

        state
        |> terminate_running_issue(issue_id, false, :stall_restart)
        |> schedule_issue_retry(issue_id, next_attempt, %{
          identifier: identifier,
          issue_url: running_entry.issue.url,
          session_id: session_id,
          error: "stalled for #{elapsed_ms}ms without codex activity"
        })
      end
    else
      state
    end
  end

  defp stall_elapsed_ms(running_entry, now) do
    running_entry
    |> last_activity_timestamp()
    |> case do
      %DateTime{} = timestamp ->
        max(0, DateTime.diff(now, timestamp, :millisecond))

      _ ->
        nil
    end
  end

  # Running entries are always maps; the stall reaper now reads other keys off
  # the same entry (`claude_tools_in_flight`), so dialyzer can prove the prior
  # non-map fallback was dead — a single clause is sufficient.
  defp last_activity_timestamp(running_entry) do
    Map.get(running_entry, :last_codex_timestamp) || Map.get(running_entry, :started_at)
  end

  defp input_required_blocker?(running_entry) when is_map(running_entry) do
    Map.get(running_entry, :last_codex_event) in [:turn_input_required, :approval_required] or
      not is_nil(input_required_completion_outcome(Map.get(running_entry, :completion))) or
      codex_message_method(Map.get(running_entry, :last_codex_message)) ==
        "mcpServer/elicitation/request"
  end

  defp input_required_blocker?(_running_entry), do: false

  defp input_required_completion_outcome(completion) when is_map(completion) do
    outcome = Map.get(completion, :outcome) || Map.get(completion, "outcome")
    normalize_input_required_outcome(outcome)
  end

  defp input_required_completion_outcome(_completion), do: nil

  defp normalize_input_required_outcome(outcome)
       when outcome in [:input_required, :needs_input, :approval_required],
       do: outcome

  defp normalize_input_required_outcome(outcome) when is_binary(outcome) do
    case outcome do
      "input_required" -> :input_required
      "needs_input" -> :needs_input
      "approval_required" -> :approval_required
      _ -> nil
    end
  end

  defp normalize_input_required_outcome(_outcome), do: nil

  defp blocker_error(running_entry, fallback) when is_map(running_entry) do
    codex_event_blocker_error(Map.get(running_entry, :last_codex_event)) ||
      completion_blocker_error(Map.get(running_entry, :completion)) ||
      codex_message_blocker_error(Map.get(running_entry, :last_codex_message)) ||
      fallback
  end

  defp blocker_error(_running_entry, fallback), do: fallback

  defp codex_event_blocker_error(:turn_input_required), do: "codex turn requires operator input"
  defp codex_event_blocker_error(:approval_required), do: "codex turn requires approval"
  defp codex_event_blocker_error(_event), do: nil

  defp completion_blocker_error(completion) do
    case input_required_completion_outcome(completion) do
      outcome when outcome in [:input_required, :needs_input] -> "codex turn requires operator input"
      :approval_required -> "codex turn requires approval"
      nil -> nil
    end
  end

  defp codex_message_blocker_error(message) do
    if codex_message_method(message) == "mcpServer/elicitation/request" do
      "codex MCP elicitation requires operator input"
    end
  end

  defp codex_message_method(%{message: %{"method" => method}}) when is_binary(method), do: method
  defp codex_message_method(%{message: %{method: method}}) when is_binary(method), do: method
  defp codex_message_method(%{"method" => method}) when is_binary(method), do: method
  defp codex_message_method(%{method: method}) when is_binary(method), do: method
  defp codex_message_method(_message), do: nil

  defp terminate_task(pid) when is_pid(pid) do
    case Task.Supervisor.terminate_child(SymphonyElixir.TaskSupervisor, pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        Process.exit(pid, :shutdown)
    end
  end

  defp terminate_task(_pid), do: :ok

  defp stop_running_task(pid, ref) do
    if is_pid(pid) do
      terminate_task(pid)
    end

    if is_reference(ref) do
      Process.demonitor(ref, [:flush])
    end

    :ok
  end

  defp stop_and_block_issue(%State{} = state, issue_id, running_entry, error) do
    stop_running_task(Map.get(running_entry, :pid), Map.get(running_entry, :ref))
    block_issue_from_entry(state, issue_id, running_entry, error)
  end

  defp block_issue_from_entry(%State{} = state, issue_id, running_entry, error) do
    blocked_entry = %{
      issue_id: issue_id,
      identifier: Map.get(running_entry, :identifier, issue_id),
      issue: Map.get(running_entry, :issue),
      worker_host: Map.get(running_entry, :worker_host),
      workspace_path: Map.get(running_entry, :workspace_path),
      session_id: running_entry_session_id(running_entry),
      error: error,
      blocked_at: DateTime.utc_now(),
      last_codex_message: Map.get(running_entry, :last_codex_message),
      last_codex_event: Map.get(running_entry, :last_codex_event),
      last_codex_timestamp: Map.get(running_entry, :last_codex_timestamp)
    }

    %{
      state
      | running: Map.delete(state.running, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        claimed: MapSet.put(state.claimed, issue_id),
        blocked: Map.put(state.blocked, issue_id, blocked_entry)
    }
  end

  defp choose_issues(issues, state) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    issues
    |> sort_issues_for_dispatch()
    |> Enum.reduce(state, fn issue, state_acc ->
      if should_dispatch_issue?(issue, state_acc, active_states, terminal_states) do
        dispatch_issue(state_acc, issue)
      else
        state_acc
      end
    end)
  end

  defp sort_issues_for_dispatch(issues) when is_list(issues) do
    Enum.sort_by(issues, fn
      %Issue{} = issue ->
        {priority_rank(issue.priority), issue_created_at_sort_key(issue), issue.identifier || issue.id || ""}

      _ ->
        {priority_rank(nil), issue_created_at_sort_key(nil), ""}
    end)
  end

  # Observability mirror only — dispatch keeps re-evaluating the predicate
  # itself. `observed_at` is preserved across polls so the dashboard can show
  # a stable "since" timestamp.
  defp refresh_dependency_blocked(%State{} = state, issues) when is_list(issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()
    previous = state.dependency_blocked
    now = DateTime.utc_now()

    next =
      issues
      |> Enum.filter(fn issue ->
        dependency_blocked_candidate?(issue, state, active_states, terminal_states)
      end)
      |> Enum.into(%{}, fn %Issue{} = issue ->
        observed_at =
          case Map.get(previous, issue.id) do
            %{observed_at: %DateTime{} = stored} -> stored
            _ -> now
          end

        {issue.id,
         %{
           identifier: issue.identifier,
           title: issue.title,
           state: issue.state,
           blocked_by: issue.blocked_by,
           observed_at: observed_at
         }}
      end)

    log_new_dependency_blocked(previous, next)
    %{state | dependency_blocked: next}
  end

  defp dependency_blocked_candidate?(%Issue{} = issue, %State{} = state, active_states, terminal_states) do
    candidate_issue?(issue, active_states, terminal_states) and
      issue_blocked_by_non_terminal?(issue, terminal_states) and
      not MapSet.member?(state.claimed, issue.id) and
      not Map.has_key?(state.running, issue.id) and
      not Map.has_key?(state.blocked, issue.id)
  end

  defp dependency_blocked_candidate?(_issue, _state, _active_states, _terminal_states), do: false

  defp log_new_dependency_blocked(previous, next) when is_map(previous) and is_map(next) do
    Enum.each(next, fn {issue_id, %{identifier: identifier}} ->
      unless Map.has_key?(previous, issue_id) do
        Logger.debug("Issue waiting on blockers: issue_id=#{issue_id} issue_identifier=#{identifier}")
      end
    end)
  end

  # Roll a parent/umbrella issue up to Done once *every* one of its sub-issues is
  # Done. Parent issues are trackers, never dispatched (see parent_issue?/1), so
  # nothing else advances them — Symphony closes them out on behalf of their
  # completed children. Acts only on parents the active-state poll returned (so
  # the parent is non-terminal: a deliberately cancelled parent is never
  # resurrected) whose full child set is present and entirely Done. Moving the
  # parent to Done drops it out of the active poll, so this fires at most once
  # per parent. Pure side effect on the tracker; the orchestrator state is
  # returned unchanged for pipelining.
  defp complete_parents_with_all_children_done(%State{} = state, issues) when is_list(issues) do
    active_states = active_state_set()

    Enum.each(issues, fn
      %Issue{} = issue -> maybe_complete_parent_issue(issue, active_states)
      _ -> :ok
    end)

    state
  end

  defp maybe_complete_parent_issue(
         %Issue{has_children: true, children: children} = parent,
         active_states
       )
       when is_list(children) and children != [] do
    cond do
      not active_issue_state?(to_string(parent.state), active_states) ->
        # Parent is already terminal (or otherwise inactive) — leave it as-is.
        :ok

      length(children) >= @subissue_child_cap ->
        Logger.debug("Skipping parent auto-complete; sub-issue list may be truncated at the fetch cap: #{issue_context(parent)} children=#{length(children)} cap=#{@subissue_child_cap}")

      all_children_done?(children) ->
        move_parent_to_done(parent)

      true ->
        :ok
    end
  end

  defp maybe_complete_parent_issue(_issue, _active_states), do: :ok

  defp all_children_done?(children) when is_list(children) do
    Enum.all?(children, fn
      %Issue{state: state} -> match_normalized_state?(to_string(state), "done")
      _ -> false
    end)
  end

  defp move_parent_to_done(%Issue{} = parent) do
    case Tracker.update_issue_state(parent.id, @parent_done_state) do
      :ok ->
        Logger.info("All sub-issues done; moved parent issue to #{@parent_done_state}: #{issue_context(parent)} from=#{inspect(parent.state)} children=#{length(parent.children)}")

      {:error, reason} ->
        Logger.warning("Failed to move parent issue to #{@parent_done_state} after all sub-issues done: #{issue_context(parent)} from=#{inspect(parent.state)} reason=#{inspect(reason)}")
    end

    :ok
  end

  defp refresh_dependency_graph(%State{} = state, issues) when is_list(issues) do
    active_states = active_state_set()
    terminal_states = terminal_state_set()

    # Anchor the graph on managed work only: a node enters the graph because this
    # instance would dispatch it (candidate_issue?/3), not merely because Linear's
    # active-state poll returned it. Non-candidate issues — active parents, leaves
    # failing assignee/label filters — are excluded as roots; they reappear only
    # as transitive blockers or as siblings of a managed child (see below).
    candidates =
      Enum.filter(issues, fn
        %Issue{} = issue -> candidate_issue?(issue, active_states, terminal_states)
        _ -> false
      end)

    known =
      candidates
      |> Enum.flat_map(fn
        %Issue{id: id} = issue when is_binary(id) -> [{id, node_projection(issue)}]
        _ -> []
      end)
      |> Map.new()

    refs = blocker_refs_index(candidates)
    frontier = frontier_for(known, refs)

    {known, refs} = expand_graph(known, frontier, refs, 0)

    known =
      known
      |> finalize_dependency_graph(refs)
      |> add_subissue_containers(issues, active_states, terminal_states)

    %{state | dependency_graph: known}
  end

  # Group sub-issues under their parent as a container node. Anchored on managed
  # work: a container is built only for the parent of a managed (candidate) leaf
  # the poll returned — never for an arbitrary polled parent issue. Once a
  # managed child anchors the parent, we surface *every* sub-issue under that
  # parent — managed or not — so the operator sees the full family. Unmanaged
  # children carry a manageability diagnostic (see `child_manageability/3`).
  # Respects the `@graph_max_nodes` cap and logs when the cap drops nodes.
  defp add_subissue_containers(known, issues, active_states, terminal_states)
       when is_map(known) and is_list(issues) do
    containers = collect_containers(issues, active_states, terminal_states)

    {known, dropped} =
      Enum.reduce(containers, {known, 0}, fn {parent_id, {parent_info, children}}, {acc, dropped} ->
        container = container_node(parent_id, parent_info, children, terminal_states)
        {acc, dropped} = put_graph_node(acc, parent_id, container, dropped)

        Enum.reduce(children, {acc, dropped}, fn %Issue{id: child_id} = child, {acc2, dropped2} ->
          node = child_node(child, parent_id, active_states, terminal_states)
          put_graph_node(acc2, child_id, node, dropped2)
        end)
      end)

    if dropped > 0 do
      Logger.debug("Dependency graph container expansion capped: dropped=#{dropped} max_nodes=#{@graph_max_nodes}")
    end

    known
  end

  # Insert a graph node, upgrading an existing placeholder to the richer node but
  # otherwise preserving an already-present real node (merging in container
  # membership). New ids are only added while under the node cap; drops are
  # counted for a single summary log.
  defp put_graph_node(known, id, node, dropped) when is_binary(id) and is_map(node) do
    case Map.get(known, id) do
      nil when map_size(known) >= @graph_max_nodes ->
        {known, dropped + 1}

      nil ->
        {Map.put(known, id, node), dropped}

      %{placeholder: true} ->
        {Map.put(known, id, node), dropped}

      existing ->
        # Real node already projected (managed/active issue). Keep it, but adopt
        # the container membership and diagnostic computed for this child.
        merged =
          existing
          |> Map.put(:parent, Map.get(node, :parent))
          |> maybe_put(:managed, Map.get(node, :managed))
          |> maybe_put(:requirements, Map.get(node, :requirements))
          |> maybe_put(:kind, Map.get(node, :kind))

        {Map.put(known, id, merged), dropped}
    end
  end

  defp put_graph_node(known, _id, _node, dropped), do: {known, dropped}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Build `parent_id => {parent_display, [child Issue]}` from the polled issues.
  # A container arises only from a managed (candidate) leaf pointing up to its
  # parent — the child carries the full sibling list via `parent.children`. An
  # active parent issue Linear happened to return does NOT anchor a container on
  # its own.
  defp collect_containers(issues, active_states, terminal_states) do
    Enum.reduce(issues, %{}, fn
      %Issue{} = issue, acc ->
        if candidate_issue?(issue, active_states, terminal_states) do
          maybe_container_from_parent(acc, issue)
        else
          acc
        end

      _other, acc ->
        acc
    end)
  end

  defp maybe_container_from_parent(acc, %Issue{parent: %Issue{id: parent_id} = parent})
       when is_binary(parent_id) do
    upsert_container(acc, parent_id, parent_info(parent), parent.children || [])
  end

  defp maybe_container_from_parent(acc, _issue), do: acc

  defp upsert_container(acc, parent_id, parent_info, children) do
    Map.update(acc, parent_id, {parent_info, children}, fn {existing_info, existing_children} ->
      {merge_parent_info(existing_info, parent_info), merge_children(existing_children, children)}
    end)
  end

  # Prefer whichever sighting of the parent carries the richer display fields
  # (a polled parent issue has identifier/state; a `parent { ... }` selection may
  # be sparser). Non-nil values win.
  defp merge_parent_info(existing, incoming) do
    Map.merge(existing, incoming, fn _k, old, new -> old || new end)
  end

  defp merge_children(existing, incoming) do
    (existing ++ incoming)
    |> Enum.reject(&match?(%Issue{id: nil}, &1))
    |> Enum.uniq_by(& &1.id)
  end

  defp parent_info(%Issue{} = parent) do
    %{
      identifier: parent.identifier,
      title: parent.title,
      state: parent.state,
      state_type: parent.state_type,
      url: parent.url
    }
  end

  defp container_node(parent_id, parent_info, children, terminal_states) do
    child_total = length(children)

    child_done =
      Enum.count(children, fn %Issue{state: state} -> terminal_issue_state?(state, terminal_states) end)

    %{
      id: parent_id,
      identifier: Map.get(parent_info, :identifier),
      title: Map.get(parent_info, :title),
      state: Map.get(parent_info, :state),
      state_type: Map.get(parent_info, :state_type),
      priority: nil,
      url: Map.get(parent_info, :url),
      blocked_by: [],
      placeholder: false,
      kind: :container,
      parent: nil,
      child_total: child_total,
      child_done: child_done
    }
  end

  defp child_node(%Issue{} = child, parent_id, active_states, terminal_states) do
    {managed, requirements} = child_manageability(child, active_states, terminal_states)

    child
    |> node_projection()
    |> Map.put(:parent, parent_id)
    |> Map.put(:managed, managed)
    |> Map.put(:requirements, requirements)
  end

  # Classify a sub-issue relative to this Symphony instance's workflow rules:
  #   * terminal-state children are done — managed, no action needed;
  #   * children that satisfy every dispatch rule are managed;
  #   * otherwise the child is unmanaged and we report what must change for this
  #     instance to pick it up (inverse of the candidate predicates).
  defp child_manageability(%Issue{state: state} = child, active_states, terminal_states) do
    cond do
      terminal_issue_state?(state, terminal_states) -> {true, []}
      candidate_issue?(child, active_states, terminal_states) -> {true, []}
      true -> {false, unmanaged_requirements(child, active_states)}
    end
  end

  defp unmanaged_requirements(%Issue{} = issue, active_states) do
    []
    |> add_requirement(parent_issue?(issue), "tracker issue — work lives in its own sub-issues")
    |> add_requirement(not issue_routable_to_worker?(issue), assignee_requirement())
    |> Enum.concat(label_requirements(issue))
    |> add_requirement(
      not active_issue_state?(to_string(issue.state), active_states),
      state_requirement()
    )
    |> Enum.reject(&is_nil/1)
  end

  defp add_requirement(reqs, true, message), do: reqs ++ [message]
  defp add_requirement(reqs, _false, _message), do: reqs

  defp assignee_requirement do
    case Config.settings!().tracker.assignee do
      assignee when is_binary(assignee) and assignee != "" -> "assign to #{assignee}"
      _ -> "assign to the configured worker"
    end
  end

  defp state_requirement do
    case Config.settings!().tracker.active_states do
      [_ | _] = states -> "move to an active state (#{Enum.join(states, ", ")})"
      _ -> "move to an active state"
    end
  end

  defp label_requirements(%Issue{labels: labels}) when is_list(labels) do
    present = MapSet.new(labels, &normalize_label/1)
    tracker = Config.settings!().tracker

    missing =
      (tracker.required_labels || [])
      |> Enum.reject(fn label -> MapSet.member?(present, normalize_label(label)) end)

    offending =
      (tracker.excluded_labels || [])
      |> Enum.filter(fn label -> MapSet.member?(present, normalize_label(label)) end)

    []
    |> add_requirement(missing != [], "add label(s): #{Enum.join(missing, ", ")}")
    |> add_requirement(offending != [], "remove label(s): #{Enum.join(offending, ", ")}")
  end

  defp label_requirements(_issue), do: []

  defp expand_graph(known, [], refs, _round), do: {known, refs}

  defp expand_graph(known, _frontier, refs, round)
       when round >= @graph_expansion_max_rounds or map_size(known) >= @graph_max_nodes do
    Logger.debug("Dependency graph expansion capped: rounds=#{round} nodes=#{map_size(known)} max_rounds=#{@graph_expansion_max_rounds} max_nodes=#{@graph_max_nodes}")

    {known, refs}
  end

  defp expand_graph(known, frontier, refs, round) do
    case Tracker.fetch_issue_states_by_ids(frontier) do
      {:ok, fetched} ->
        {merged_known, new_refs} =
          Enum.reduce(fetched, {known, refs}, fn
            %Issue{id: id} = issue, {acc_known, acc_refs} when is_binary(id) ->
              acc_known = Map.put(acc_known, id, node_projection(issue))
              acc_refs = Map.merge(acc_refs, refs_from_issue(issue))
              {acc_known, acc_refs}

            _, acc ->
              acc
          end)

        next_frontier = frontier_for(merged_known, new_refs)
        expand_graph(merged_known, next_frontier, new_refs, round + 1)

      {:error, reason} ->
        Logger.debug("Dependency graph expansion fetch failed: #{inspect(reason)}; using last-known refs as placeholders")
        {known, refs}
    end
  end

  defp finalize_dependency_graph(known, refs) when is_map(known) and is_map(refs) do
    Enum.reduce(refs, known, fn {ref_id, ref_meta}, acc ->
      if Map.has_key?(acc, ref_id) or map_size(acc) >= @graph_max_nodes do
        acc
      else
        Map.put(acc, ref_id, placeholder_node(ref_id, ref_meta))
      end
    end)
  end

  defp node_projection(%Issue{} = issue) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      state_type: issue.state_type,
      priority: issue.priority,
      url: issue.url,
      blocked_by: issue.blocked_by || [],
      placeholder: false,
      kind: :issue,
      parent: nil
    }
  end

  defp placeholder_node(ref_id, ref_meta) do
    %{
      id: ref_id,
      identifier: Map.get(ref_meta, :identifier),
      title: nil,
      state: Map.get(ref_meta, :state),
      state_type: nil,
      priority: nil,
      url: nil,
      blocked_by: [],
      placeholder: true,
      kind: :issue,
      parent: nil
    }
  end

  defp blocker_refs_index(issues) when is_list(issues) do
    Enum.reduce(issues, %{}, fn
      %Issue{} = issue, acc -> Map.merge(acc, refs_from_issue(issue))
      _, acc -> acc
    end)
  end

  defp refs_from_issue(%Issue{blocked_by: blockers}) when is_list(blockers) do
    Enum.reduce(blockers, %{}, fn
      %{id: id} = ref, acc when is_binary(id) ->
        Map.put(acc, id, %{
          identifier: Map.get(ref, :identifier),
          state: Map.get(ref, :state)
        })

      _, acc ->
        acc
    end)
  end

  defp refs_from_issue(_issue), do: %{}

  defp frontier_for(known, refs) when is_map(known) and is_map(refs) do
    refs
    |> Map.keys()
    |> Enum.reject(fn id -> is_nil(id) or Map.has_key?(known, id) end)
    |> Enum.uniq()
  end

  defp priority_rank(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp priority_rank(_priority), do: 5

  defp issue_created_at_sort_key(%Issue{created_at: %DateTime{} = created_at}) do
    DateTime.to_unix(created_at, :microsecond)
  end

  defp issue_created_at_sort_key(%Issue{}), do: 9_223_372_036_854_775_807
  defp issue_created_at_sort_key(_issue), do: 9_223_372_036_854_775_807

  defp should_dispatch_issue?(
         %Issue{} = issue,
         %State{running: running, claimed: claimed, blocked: blocked} = state,
         active_states,
         terminal_states
       ) do
    candidate_issue?(issue, active_states, terminal_states) and
      !issue_blocked_by_non_terminal?(issue, terminal_states) and
      !MapSet.member?(claimed, issue.id) and
      !Map.has_key?(running, issue.id) and
      !Map.has_key?(blocked, issue.id) and
      available_slots(state) > 0 and
      state_slots_available?(issue, running) and
      worker_slots_available?(state) and
      active_provider_quota_allows_dispatch(state) == :ok
  end

  defp should_dispatch_issue?(_issue, _state, _active_states, _terminal_states), do: false

  defp state_slots_available?(%Issue{state: issue_state}, running) when is_map(running) do
    limit = Config.max_concurrent_agents_for_state(issue_state)
    used = running_issue_count_for_state(running, issue_state)
    limit > used
  end

  defp state_slots_available?(_issue, _running), do: false

  defp running_issue_count_for_state(running, issue_state) when is_map(running) do
    normalized_state = normalize_issue_state(issue_state)

    Enum.count(running, fn
      {_id, %{issue: %Issue{state: state_name}}} ->
        normalize_issue_state(state_name) == normalized_state

      _ ->
        false
    end)
  end

  defp candidate_issue?(
         %Issue{
           id: id,
           identifier: identifier,
           title: title,
           state: state_name
         } = issue,
         active_states,
         terminal_states
       )
       when is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state_name) do
    issue_routable_to_worker?(issue) and
      issue_satisfies_label_filters?(issue) and
      !parent_issue?(issue) and
      active_issue_state?(state_name, active_states) and
      !terminal_issue_state?(state_name, terminal_states)
  end

  defp candidate_issue?(_issue, _active_states, _terminal_states), do: false

  # Parent/umbrella issues (those with sub-issues) are trackers, not work
  # units — their work lives in the children. Claiming a parent makes the
  # agent re-implement a sub-issue's scope and collide with the sub-issue's
  # own PR, so they are never dispatch-eligible.
  defp parent_issue?(%Issue{has_children: true}), do: true
  defp parent_issue?(%Issue{}), do: false

  defp issue_routable_to_worker?(%Issue{assigned_to_worker: assigned_to_worker})
       when is_boolean(assigned_to_worker),
       do: assigned_to_worker

  defp issue_routable_to_worker?(_issue), do: true

  # Dispatch only when the issue carries every `required_labels` entry (all-of)
  # and none of the `excluded_labels` entries (none-of). Empty lists are no-ops.
  defp issue_satisfies_label_filters?(%Issue{labels: labels}) when is_list(labels) do
    present = MapSet.new(labels, &normalize_label/1)

    MapSet.subset?(required_label_set(), present) and
      MapSet.disjoint?(excluded_label_set(), present)
  end

  defp issue_blocked_by_non_terminal?(%Issue{blocked_by: blockers}, terminal_states)
       when is_list(blockers) do
    Enum.any?(blockers, fn
      %{state: blocker_state} when is_binary(blocker_state) ->
        !terminal_issue_state?(blocker_state, terminal_states)

      _ ->
        true
    end)
  end

  defp issue_blocked_by_non_terminal?(_issue, _terminal_states), do: false

  defp terminal_issue_state?(state_name, terminal_states) when is_binary(state_name) do
    MapSet.member?(terminal_states, normalize_issue_state(state_name))
  end

  defp terminal_issue_state?(_state_name, _terminal_states), do: false

  defp active_issue_state?(state_name, active_states) when is_binary(state_name) do
    MapSet.member?(active_states, normalize_issue_state(state_name))
  end

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    String.downcase(String.trim(state_name))
  end

  defp match_normalized_state?(state_name, normalized) when is_binary(normalized) do
    normalize_issue_state(state_name) == normalized
  end

  defp normalize_label(label) when is_binary(label) do
    String.downcase(String.trim(label))
  end

  defp required_label_set, do: label_set(Config.settings!().tracker.required_labels)

  defp excluded_label_set, do: label_set(Config.settings!().tracker.excluded_labels)

  defp label_set(labels) when is_list(labels) do
    labels
    |> Enum.map(&normalize_label/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp terminal_state_set do
    Config.settings!().tracker.terminal_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp active_state_set do
    Config.settings!().tracker.active_states
    |> Enum.map(&normalize_issue_state/1)
    |> Enum.filter(&(&1 != ""))
    |> MapSet.new()
  end

  defp dispatch_issue(%State{} = state, issue, attempt \\ nil, preferred_worker_host \\ nil) do
    case revalidate_issue_for_dispatch(issue, &Tracker.fetch_issue_states_by_ids/1, terminal_state_set()) do
      {:ok, %Issue{} = refreshed_issue} ->
        case active_provider_quota_allows_dispatch(state) do
          :ok ->
            do_dispatch_issue(state, refreshed_issue, attempt, preferred_worker_host)

          {:paused, provider, threshold} ->
            Logger.info("Skipping dispatch; #{provider} quota is at or above #{threshold}%")
            state
        end

      {:skip, :missing} ->
        Logger.info("Skipping dispatch; issue no longer active or visible: #{issue_context(issue)}")
        state

      {:skip, %Issue{} = refreshed_issue} ->
        Logger.info("Skipping stale dispatch after issue refresh: #{issue_context(refreshed_issue)} state=#{inspect(refreshed_issue.state)} blocked_by=#{length(refreshed_issue.blocked_by)}")

        state

      {:error, :rate_limited} ->
        Logger.debug("Skipping dispatch; Linear rate-limit window active for #{issue_context(issue)}")

        state

      {:error, reason} ->
        Logger.warning("Skipping dispatch; issue refresh failed for #{issue_context(issue)}: #{inspect(reason)}")
        state
    end
  end

  defp do_dispatch_issue(%State{} = state, issue, attempt, preferred_worker_host) do
    recipient = self()

    case select_worker_host(state, preferred_worker_host) do
      :no_worker_capacity ->
        Logger.debug("No SSH worker slots available for #{issue_context(issue)} preferred_worker_host=#{inspect(preferred_worker_host)}")
        state

      worker_host ->
        spawn_issue_on_worker_host(state, issue, attempt, recipient, worker_host)
    end
  end

  defp spawn_issue_on_worker_host(%State{} = state, issue, attempt, recipient, worker_host) do
    resume_after_block = Map.get(state.rebase_pending, issue.id)

    case Task.Supervisor.start_child(agent_task_supervisor(), fn ->
           AgentRunner.run(issue, recipient,
             attempt: attempt,
             worker_host: worker_host,
             resume_after_block: resume_after_block
           )
         end) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        log_resume_after_block(issue, resume_after_block)

        Logger.info("Dispatching issue to agent: #{issue_context(issue)} pid=#{inspect(pid)} attempt=#{inspect(attempt)} worker_host=#{worker_host || "local"}")

        running =
          Map.put(state.running, issue.id, %{
            pid: pid,
            ref: ref,
            identifier: issue.identifier,
            issue: issue,
            worker_host: worker_host,
            workspace_path: nil,
            session_id: nil,
            agent_kind: agent_kind_for_adapter(Config.adapter_module()),
            last_codex_message: nil,
            last_codex_timestamp: nil,
            last_codex_event: nil,
            codex_app_server_pid: nil,
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            claude_app_server_pid: nil,
            claude_input_tokens: 0,
            claude_output_tokens: 0,
            claude_total_tokens: 0,
            claude_cache_creation_input_tokens: 0,
            claude_cache_read_input_tokens: 0,
            # Count of native Claude tool calls (Bash/Read/…) currently
            # executing, tracked from sidecar tool_started/tool_finished hooks.
            # While > 0 the stall watchdog uses the longer tool-stall window.
            claude_tools_in_flight: 0,
            claude_turn_provisional_input_tokens: 0,
            claude_turn_provisional_output_tokens: 0,
            claude_turn_provisional_total_tokens: 0,
            claude_turn_provisional_cache_creation_input_tokens: 0,
            claude_turn_provisional_cache_read_input_tokens: 0,
            turn_count: 0,
            # Per-turn deterministic progress signals (IDE-211 / Layer 1).
            # Rolling streaks + last assessment; advanced at each turn boundary.
            progress: ProgressSignal.initial(),
            retry_attempt: normalize_retry_attempt(attempt),
            started_at: DateTime.utc_now()
          })

        %{
          state
          | running: running,
            claimed: MapSet.put(state.claimed, issue.id),
            retry_attempts: Map.delete(state.retry_attempts, issue.id),
            rebase_pending: Map.delete(state.rebase_pending, issue.id)
        }
        |> bump_session_count(issue.id)

      {:error, reason} ->
        Logger.error("Unable to spawn agent for #{issue_context(issue)}: #{inspect(reason)}")
        next_attempt = if is_integer(attempt), do: attempt + 1, else: nil

        schedule_issue_retry(state, issue.id, next_attempt, %{
          identifier: issue.identifier,
          issue_url: issue.url,
          error: "failed to spawn agent: #{inspect(reason)}",
          worker_host: worker_host
        })
    end
  end

  defp log_resume_after_block(issue, %{blockers: blockers}) do
    Logger.info("Resuming dependency-unblocked issue with rebase-on-resume directive: #{issue_context(issue)} blockers=#{inspect(blockers)}")
  end

  defp log_resume_after_block(_issue, _resume_after_block), do: :ok

  defp revalidate_issue_for_dispatch(%Issue{id: issue_id}, issue_fetcher, terminal_states)
       when is_binary(issue_id) and is_function(issue_fetcher, 1) do
    case issue_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if retry_candidate_issue?(refreshed_issue, terminal_states) do
          {:ok, refreshed_issue}
        else
          {:skip, refreshed_issue}
        end

      {:ok, []} ->
        {:skip, :missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp revalidate_issue_for_dispatch(issue, _issue_fetcher, _terminal_states), do: {:ok, issue}

  defp complete_issue(%State{} = state, issue_id) do
    %{
      state
      | completed: MapSet.put(state.completed, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id)
    }
  end

  defp schedule_issue_retry(%State{} = state, issue_id, attempt, metadata)
       when is_binary(issue_id) and is_map(metadata) do
    previous_retry = Map.get(state.retry_attempts, issue_id, %{attempt: 0})
    next_attempt = if is_integer(attempt), do: attempt, else: previous_retry.attempt + 1
    delay_ms = retry_delay(next_attempt, metadata)
    old_timer = Map.get(previous_retry, :timer_ref)
    retry_token = make_ref()
    due_at_ms = System.monotonic_time(:millisecond) + delay_ms
    identifier = pick_retry_identifier(issue_id, previous_retry, metadata)
    issue_url = pick_retry_issue_url(previous_retry, metadata)
    error = pick_retry_error(previous_retry, metadata)
    worker_host = pick_retry_worker_host(previous_retry, metadata)
    workspace_path = pick_retry_workspace_path(previous_retry, metadata)
    session_id = pick_retry_session_id(previous_retry, metadata)

    if is_reference(old_timer) do
      Process.cancel_timer(old_timer)
    end

    timer_ref = Process.send_after(self(), {:retry_issue, issue_id, retry_token}, delay_ms)

    error_suffix = if is_binary(error), do: " error=#{error}", else: ""

    Logger.warning("Retrying issue_id=#{issue_id} issue_identifier=#{identifier} session_id=#{session_id} in #{delay_ms}ms (attempt #{next_attempt})#{error_suffix}")

    %{
      state
      | retry_attempts:
          Map.put(state.retry_attempts, issue_id, %{
            attempt: next_attempt,
            timer_ref: timer_ref,
            retry_token: retry_token,
            due_at_ms: due_at_ms,
            identifier: identifier,
            issue_url: issue_url,
            session_id: session_id,
            error: error,
            worker_host: worker_host,
            workspace_path: workspace_path
          })
    }
  end

  defp pop_retry_attempt_state(%State{} = state, issue_id, retry_token) when is_reference(retry_token) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt, retry_token: ^retry_token} = retry_entry ->
        metadata = %{
          identifier: Map.get(retry_entry, :identifier),
          issue_url: Map.get(retry_entry, :issue_url),
          session_id: Map.get(retry_entry, :session_id),
          error: Map.get(retry_entry, :error),
          worker_host: Map.get(retry_entry, :worker_host),
          workspace_path: Map.get(retry_entry, :workspace_path)
        }

        {:ok, attempt, metadata, %{state | retry_attempts: Map.delete(state.retry_attempts, issue_id)}}

      _ ->
        :missing
    end
  end

  defp handle_retry_issue(%State{} = state, issue_id, attempt, metadata) do
    case Tracker.fetch_candidate_issues() do
      {:ok, issues} ->
        issues
        |> find_issue_by_id(issue_id)
        |> handle_retry_issue_lookup(state, issue_id, attempt, metadata)

      {:error, :rate_limited} ->
        Logger.debug("Retry poll deferred; Linear rate-limit window active for issue_id=#{issue_id}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll deferred: rate_limited"})
         )}

      {:error, reason} ->
        Logger.warning("Retry poll failed for issue_id=#{issue_id} issue_identifier=#{metadata[:identifier] || issue_id} session_id=#{metadata[:session_id] || "unknown"}: #{inspect(reason)}")

        {:noreply,
         schedule_issue_retry(
           state,
           issue_id,
           attempt + 1,
           Map.merge(metadata, %{error: "retry poll failed: #{inspect(reason)}"})
         )}
    end
  end

  defp handle_retry_issue_lookup(%Issue{} = issue, state, issue_id, attempt, metadata) do
    terminal_states = terminal_state_set()

    cond do
      terminal_issue_state?(issue.state, terminal_states) ->
        Logger.info("Issue state is terminal: issue_id=#{issue_id} issue_identifier=#{issue.identifier} state=#{issue.state}; removing associated workspace")

        cleanup_issue_workspace(issue.identifier, metadata[:worker_host])
        {:noreply, release_issue_claim(state, issue_id)}

      retry_candidate_issue?(issue, terminal_states) ->
        handle_active_retry(state, issue, attempt, metadata)

      true ->
        Logger.debug("Issue left active states, removing claim issue_id=#{issue_id} issue_identifier=#{issue.identifier}")

        {:noreply, release_issue_claim(state, issue_id)}
    end
  end

  defp handle_retry_issue_lookup(nil, state, issue_id, _attempt, _metadata) do
    Logger.debug("Issue no longer visible, removing claim issue_id=#{issue_id}")
    {:noreply, release_issue_claim(state, issue_id)}
  end

  # Best-effort non-destructive snapshot of uncommitted work before a cutoff
  # (IDE-189). Gated on `agent.preserve_uncommitted_work`; failures are logged
  # and swallowed so preservation can never block a stop or retry. Requires a
  # known `workspace_path` (populated via `{:worker_runtime_info, ...}`).
  defp maybe_preserve_uncommitted_work(running_entry, issue_id, identifier, cutoff_reason) do
    if Config.preserve_uncommitted_work?() do
      case Map.get(running_entry, :workspace_path) do
        workspace when is_binary(workspace) ->
          opts = [
            branch: Config.preserve_uncommitted_work_branch?(),
            reason: cutoff_reason,
            timeout_ms: Config.cutoff_timeout_ms()
          ]

          log_preservation_result(
            Git.preserve_uncommitted_work(workspace, identifier, Map.get(running_entry, :worker_host), opts),
            issue_id,
            identifier,
            cutoff_reason
          )

        _ ->
          Logger.debug("Skipping work preservation; no workspace_path issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{cutoff_reason}")
      end
    end
  end

  defp log_preservation_result({:ok, :clean}, issue_id, identifier, reason) do
    Logger.debug("Work preservation skipped clean tree issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{reason}")
  end

  defp log_preservation_result({:ok, {:preserved, sha, ref}}, issue_id, identifier, reason) do
    Logger.info("Preserved uncommitted work issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{reason} commit=#{sha} ref=#{ref}")
  end

  defp log_preservation_result({:error, error}, issue_id, identifier, reason) do
    Logger.warning("Failed to preserve uncommitted work issue_id=#{issue_id} issue_identifier=#{identifier} reason=#{reason} error=#{inspect(error)}")
  end

  defp cleanup_issue_workspace(identifier, worker_host \\ nil)

  defp cleanup_issue_workspace(identifier, worker_host) when is_binary(identifier) do
    Workspace.remove_issue_workspaces(identifier, worker_host)
  end

  defp cleanup_issue_workspace(_identifier, _worker_host), do: :ok

  defp blocked_issue_worker_host(%State{} = state, issue_id) do
    state.blocked
    |> Map.get(issue_id, %{})
    |> Map.get(:worker_host)
  end

  defp run_terminal_workspace_cleanup do
    case Tracker.fetch_issues_by_states(Config.settings!().tracker.terminal_states) do
      {:ok, issues} ->
        issues
        |> Enum.each(fn
          %Issue{identifier: identifier} when is_binary(identifier) ->
            cleanup_issue_workspace(identifier)

          _ ->
            :ok
        end)

      {:error, reason} ->
        Logger.warning("Skipping startup terminal workspace cleanup; failed to fetch terminal issues: #{inspect(reason)}")
    end
  end

  defp notify_dashboard do
    StatusDashboard.notify_update()
  end

  defp agent_kind_for_adapter(SymphonyElixir.Claude.AppServer), do: :claude
  defp agent_kind_for_adapter(_other), do: :codex

  defp handle_active_retry(state, issue, attempt, metadata) do
    if retry_candidate_issue?(issue, terminal_state_set()) and
         dispatch_slots_available?(issue, state) and
         worker_slots_available?(state, metadata[:worker_host]) do
      {:noreply, dispatch_issue(state, issue, attempt, metadata[:worker_host])}
    else
      Logger.debug("No available slots for retrying #{issue_context(issue)}; retrying again")

      {:noreply,
       schedule_issue_retry(
         state,
         issue.id,
         attempt + 1,
         Map.merge(metadata, %{
           identifier: issue.identifier,
           error: "no available orchestrator slots"
         })
       )}
    end
  end

  defp release_issue_claim(%State{} = state, issue_id) do
    %{
      state
      | claimed: MapSet.delete(state.claimed, issue_id),
        blocked: Map.delete(state.blocked, issue_id),
        retry_attempts: Map.delete(state.retry_attempts, issue_id),
        deterministic_failures: DeterministicFailure.reset(state.deterministic_failures, issue_id),
        pending_escalations: Map.delete(state.pending_escalations, issue_id)
    }
    |> close_session_episode(issue_id)
  end

  defp retry_delay(attempt, metadata) when is_integer(attempt) and attempt > 0 and is_map(metadata) do
    cond do
      metadata[:delay_type] == :continuation and attempt == 1 ->
        @continuation_retry_delay_ms

      is_integer(metadata[:delay_ms_override]) and metadata[:delay_ms_override] > 0 ->
        metadata[:delay_ms_override]

      true ->
        failure_retry_delay(attempt)
    end
  end

  defp failure_retry_delay(attempt) do
    max_delay_power = min(attempt - 1, 10)
    min(@failure_retry_base_ms * (1 <<< max_delay_power), Config.settings!().agent.max_retry_backoff_ms)
  end

  defp normalize_retry_attempt(attempt) when is_integer(attempt) and attempt > 0, do: attempt
  defp normalize_retry_attempt(_attempt), do: 0

  defp next_retry_attempt_from_running(running_entry) do
    case Map.get(running_entry, :retry_attempt) do
      attempt when is_integer(attempt) and attempt > 0 -> attempt + 1
      _ -> nil
    end
  end

  defp pick_retry_identifier(issue_id, previous_retry, metadata) do
    metadata[:identifier] || Map.get(previous_retry, :identifier) || issue_id
  end

  defp pick_retry_issue_url(previous_retry, metadata) do
    metadata[:issue_url] || Map.get(previous_retry, :issue_url)
  end

  defp pick_retry_error(previous_retry, metadata) do
    metadata[:error] || Map.get(previous_retry, :error)
  end

  defp pick_retry_worker_host(previous_retry, metadata) do
    metadata[:worker_host] || Map.get(previous_retry, :worker_host)
  end

  defp pick_retry_workspace_path(previous_retry, metadata) do
    metadata[:workspace_path] || Map.get(previous_retry, :workspace_path)
  end

  defp pick_retry_session_id(previous_retry, metadata) do
    metadata[:session_id] || Map.get(previous_retry, :session_id) || "unknown"
  end

  defp maybe_put_runtime_value(running_entry, _key, nil), do: running_entry

  defp maybe_put_runtime_value(running_entry, key, value) when is_map(running_entry) do
    Map.put(running_entry, key, value)
  end

  defp select_worker_host(%State{} = state, preferred_worker_host) do
    case Config.settings!().worker.ssh_hosts do
      [] ->
        nil

      hosts ->
        available_hosts = Enum.filter(hosts, &worker_host_slots_available?(state, &1))

        cond do
          available_hosts == [] ->
            :no_worker_capacity

          preferred_worker_host_available?(preferred_worker_host, available_hosts) ->
            preferred_worker_host

          true ->
            least_loaded_worker_host(state, available_hosts)
        end
    end
  end

  defp preferred_worker_host_available?(preferred_worker_host, hosts)
       when is_binary(preferred_worker_host) and is_list(hosts) do
    preferred_worker_host != "" and preferred_worker_host in hosts
  end

  defp preferred_worker_host_available?(_preferred_worker_host, _hosts), do: false

  defp least_loaded_worker_host(%State{} = state, hosts) when is_list(hosts) do
    hosts
    |> Enum.with_index()
    |> Enum.min_by(fn {host, index} ->
      {running_worker_host_count(state.running, host), index}
    end)
    |> elem(0)
  end

  defp running_worker_host_count(running, worker_host) when is_map(running) and is_binary(worker_host) do
    Enum.count(running, fn
      {_issue_id, %{worker_host: ^worker_host}} -> true
      _ -> false
    end)
  end

  defp worker_slots_available?(%State{} = state) do
    select_worker_host(state, nil) != :no_worker_capacity
  end

  defp worker_slots_available?(%State{} = state, preferred_worker_host) do
    select_worker_host(state, preferred_worker_host) != :no_worker_capacity
  end

  defp worker_host_slots_available?(%State{} = state, worker_host) when is_binary(worker_host) do
    case Config.settings!().worker.max_concurrent_agents_per_host do
      limit when is_integer(limit) and limit > 0 ->
        running_worker_host_count(state.running, worker_host) < limit

      _ ->
        true
    end
  end

  defp find_issue_by_id(issues, issue_id) when is_binary(issue_id) do
    Enum.find(issues, fn
      %Issue{id: ^issue_id} ->
        true

      _ ->
        false
    end)
  end

  defp find_issue_id_for_ref(running, ref) do
    running
    |> Enum.find_value(fn {issue_id, %{ref: running_ref}} ->
      if running_ref == ref, do: issue_id
    end)
  end

  defp running_entry_session_id(%{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp running_entry_session_id(_running_entry), do: "n/a"

  defp running_entry_identifier(%{identifier: identifier}, _issue_id) when is_binary(identifier),
    do: identifier

  defp running_entry_identifier(_running_entry, issue_id), do: issue_id

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp available_slots(%State{} = state) do
    max(
      (state.max_concurrent_agents || Config.settings!().agent.max_concurrent_agents) -
        map_size(state.running),
      0
    )
  end

  # Re-derived at snapshot time so the status reflects live state-map
  # membership rather than what was true at the last successful poll.
  defp derive_symphony_status(%State{} = state, issue_id) do
    cond do
      Map.has_key?(state.running, issue_id) -> :running
      Map.has_key?(state.retry_attempts, issue_id) -> :retrying
      Map.has_key?(state.blocked, issue_id) -> :blocked
      Map.has_key?(Map.get(state, :dependency_blocked, %{}), issue_id) -> :waiting_on_blockers
      true -> nil
    end
  end

  # Active/last-active session id for a graph node, joined from whichever
  # tracking map still holds the issue (running > blocked > retrying). Entries
  # are dropped once an issue leaves those states, so completed/idle issues
  # report nil and the dashboard renders "-".
  defp graph_session_id(%State{} = state, issue_id) do
    graph_entry_field(state, issue_id, :session_id)
  end

  defp graph_workspace_path(%State{} = state, issue_id) do
    graph_entry_field(state, issue_id, :workspace_path)
  end

  defp graph_entry_field(%State{} = state, issue_id, key) do
    entry =
      Map.get(state.running, issue_id) ||
        Map.get(state.blocked, issue_id) ||
        Map.get(state.retry_attempts, issue_id)

    case entry do
      %{} = metadata ->
        case Map.get(metadata, key) do
          value when is_binary(value) -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Short human explanation of why a node has no live agent session. Returns nil
  # for running issues (a session is active, so no reason is needed).
  # Container (parent/umbrella) nodes summarize sub-issue progress rather than a
  # dispatch state, so they intercept ahead of the status-keyed clauses.
  defp graph_inactive_reason(_state, _issue_id, _status, %{kind: :container} = node) do
    done = Map.get(node, :child_done, 0)
    total = Map.get(node, :child_total, 0)
    "#{done}/#{total} sub-issues done"
  end

  defp graph_inactive_reason(_state, _issue_id, :running, _node), do: nil

  defp graph_inactive_reason(%State{} = state, issue_id, :retrying, _node) do
    case Map.get(state.retry_attempts, issue_id) do
      %{attempt: attempt} = retry ->
        case Map.get(retry, :error) do
          error when is_binary(error) and error != "" -> "Retry #{attempt}: #{error}"
          _ -> "Retry #{attempt}: waiting to retry"
        end

      _ ->
        "Waiting to retry"
    end
  end

  defp graph_inactive_reason(%State{} = state, issue_id, :blocked, _node) do
    case Map.get(state.blocked, issue_id) do
      %{error: error} when is_binary(error) and error != "" -> error
      _ -> "Blocked — operator attention required"
    end
  end

  defp graph_inactive_reason(%State{} = state, issue_id, :waiting_on_blockers, node) do
    blockers =
      case Map.get(Map.get(state, :dependency_blocked, %{}), issue_id) do
        %{blocked_by: blocked_by} when is_list(blocked_by) -> blocked_by
        _ -> Map.get(node, :blocked_by, [])
      end

    "Waiting on #{length(blockers)} blocker(s)"
  end

  # Unmanaged sub-issues explain what must change for this instance to pick them
  # up (the inverse of the dispatch rules), computed at graph-build time.
  defp graph_inactive_reason(_state, _issue_id, nil, %{managed: false, requirements: [_ | _] = requirements}) do
    "Needs: " <> Enum.join(requirements, "; ")
  end

  defp graph_inactive_reason(%State{} = state, issue_id, nil, node) do
    cond do
      Map.get(node, :placeholder, false) == true -> "External blocker"
      Map.get(node, :state_type) == "completed" -> "Completed"
      Map.get(node, :state_type) == "canceled" -> "Canceled"
      MapSet.member?(state.completed, issue_id) -> "Completed"
      true -> "Idle — not yet dispatched"
    end
  end

  @spec request_refresh() :: map() | :unavailable
  def request_refresh do
    request_refresh(__MODULE__)
  end

  @spec request_refresh(GenServer.server()) :: map() | :unavailable
  def request_refresh(server) do
    if Process.whereis(server) do
      GenServer.call(server, :request_refresh)
    else
      :unavailable
    end
  end

  @spec snapshot() :: map() | :timeout | :unavailable
  def snapshot, do: snapshot(__MODULE__, 15_000)

  @spec snapshot(GenServer.server(), timeout()) :: map() | :timeout | :unavailable
  def snapshot(server, timeout) do
    if Process.whereis(server) do
      try do
        GenServer.call(server, :snapshot, timeout)
      catch
        :exit, {:timeout, _} -> :timeout
        :exit, _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = refresh_runtime_config(state)
    now = DateTime.utc_now()
    now_ms = System.monotonic_time(:millisecond)

    running =
      state.running
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: metadata.identifier,
          issue_url: metadata.issue.url,
          state: metadata.issue.state,
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: metadata.session_id,
          agent_kind: Map.get(metadata, :agent_kind, :codex),
          codex_app_server_pid: Map.get(metadata, :codex_app_server_pid),
          codex_input_tokens: Map.get(metadata, :codex_input_tokens, 0),
          codex_output_tokens: Map.get(metadata, :codex_output_tokens, 0),
          codex_total_tokens: Map.get(metadata, :codex_total_tokens, 0),
          claude_app_server_pid: Map.get(metadata, :claude_app_server_pid),
          claude_input_tokens: Map.get(metadata, :claude_input_tokens, 0),
          claude_output_tokens: Map.get(metadata, :claude_output_tokens, 0),
          claude_total_tokens: Map.get(metadata, :claude_total_tokens, 0),
          claude_cache_creation_input_tokens: Map.get(metadata, :claude_cache_creation_input_tokens, 0),
          claude_cache_read_input_tokens: Map.get(metadata, :claude_cache_read_input_tokens, 0),
          turn_count: Map.get(metadata, :turn_count, 0),
          progress_assessment: progress_assessment(metadata),
          started_at: metadata.started_at,
          last_codex_timestamp: metadata.last_codex_timestamp,
          last_codex_message: metadata.last_codex_message,
          last_codex_event: metadata.last_codex_event,
          runtime_seconds: running_seconds(metadata.started_at, now)
        }
      end)

    retrying =
      state.retry_attempts
      |> Enum.map(fn {issue_id, %{attempt: attempt, due_at_ms: due_at_ms} = retry} ->
        %{
          issue_id: issue_id,
          attempt: attempt,
          due_in_ms: max(0, due_at_ms - now_ms),
          identifier: Map.get(retry, :identifier),
          issue_url: Map.get(retry, :issue_url),
          error: Map.get(retry, :error),
          worker_host: Map.get(retry, :worker_host),
          workspace_path: Map.get(retry, :workspace_path)
        }
      end)

    blocked =
      state.blocked
      |> Enum.map(fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          issue_url: blocked_issue_url(metadata),
          state: blocked_issue_state(metadata),
          worker_host: Map.get(metadata, :worker_host),
          workspace_path: Map.get(metadata, :workspace_path),
          session_id: Map.get(metadata, :session_id),
          error: Map.get(metadata, :error),
          blocked_at: Map.get(metadata, :blocked_at),
          last_codex_timestamp: Map.get(metadata, :last_codex_timestamp),
          last_codex_message: Map.get(metadata, :last_codex_message),
          last_codex_event: Map.get(metadata, :last_codex_event)
        }
      end)

    dependency_blocked_map = Map.get(state, :dependency_blocked, %{})
    dependency_graph_map = Map.get(state, :dependency_graph, %{})

    dependency_blocked =
      Enum.map(dependency_blocked_map, fn {issue_id, metadata} ->
        %{
          issue_id: issue_id,
          identifier: Map.get(metadata, :identifier),
          title: Map.get(metadata, :title),
          state: Map.get(metadata, :state),
          blocked_by: Map.get(metadata, :blocked_by, []),
          observed_at: Map.get(metadata, :observed_at)
        }
      end)

    dependency_graph =
      Enum.map(dependency_graph_map, fn {issue_id, node} ->
        status = derive_symphony_status(state, issue_id)

        node
        |> Map.put(:issue_id, issue_id)
        |> Map.put(:symphony_status, status)
        |> Map.put(:session_id, graph_session_id(state, issue_id))
        |> Map.put(:workspace_path, graph_workspace_path(state, issue_id))
        |> Map.put(:inactive_reason, graph_inactive_reason(state, issue_id, status, node))
      end)

    {:reply,
     %{
       running: running,
       retrying: retrying,
       blocked: blocked,
       dependency_blocked: dependency_blocked,
       dependency_graph: dependency_graph,
       codex_totals: state.codex_totals,
       claude_totals: state.claude_totals,
       rate_limits: codex_raw_rate_limits(state.provider_quotas),
       provider_quotas: ensure_provider_quotas(state.provider_quotas),
       polling: %{
         checking?: state.poll_check_in_progress == true,
         next_poll_in_ms: next_poll_in_ms(state.next_poll_due_at_ms, now_ms),
         poll_interval_ms: state.poll_interval_ms
       }
     }, state}
  end

  def handle_call(:request_refresh, _from, state) do
    now_ms = System.monotonic_time(:millisecond)
    already_due? = is_integer(state.next_poll_due_at_ms) and state.next_poll_due_at_ms <= now_ms
    coalesced = state.poll_check_in_progress == true or already_due?
    state = if coalesced, do: state, else: schedule_tick(state, 0)

    {:reply,
     %{
       queued: true,
       coalesced: coalesced,
       requested_at: DateTime.utc_now(),
       operations: ["poll", "reconcile"]
     }, state}
  end

  # Branch on `update[:agent_kind]`; the Claude AppServer stamps `:claude` on
  # every envelope. Anything else (including missing) stays on the codex path
  # so existing fixtures and codex-only tests keep working.
  defp handle_worker_update(state, running, issue_id, running_entry, %{agent_kind: :claude} = update) do
    {updated_running_entry, token_delta} = integrate_claude_update(running_entry, update)
    updated_running_entry = maybe_assess_progress(running_entry, updated_running_entry, issue_id, update)

    state
    |> apply_claude_token_delta(token_delta)
    |> Map.put(:running, Map.put(running, issue_id, updated_running_entry))
  end

  defp handle_worker_update(state, running, issue_id, running_entry, update) do
    {updated_running_entry, token_delta} = integrate_codex_update(running_entry, update)
    updated_running_entry = maybe_assess_progress(running_entry, updated_running_entry, issue_id, update)

    state
    |> apply_codex_token_delta(token_delta)
    |> apply_codex_rate_limits(update)
    |> Map.put(:running, Map.put(running, issue_id, updated_running_entry))
  end

  # Layer-1 progress signals (IDE-211). Runs exactly once per *turn boundary* —
  # when `integrate_*_update` advanced `turn_count` — gated on
  # `agent.progress_signal_enabled`. The git probe runs in the orchestrator
  # process *after* the turn completed (off the agent's critical path) and is
  # bounded by `agent.progress_signal_git_timeout_ms`, so a slow/locked repo
  # degrades to "assessment unchanged" rather than stalling the loop. Reports &
  # logs only — no kill, no state move, no continuation gating (Layers 0/2).
  defp maybe_assess_progress(prev_entry, updated_entry, issue_id, update) do
    if turn_boundary?(prev_entry, updated_entry) and Config.progress_signal_enabled?() do
      assess_progress(updated_entry, issue_id, update)
    else
      updated_entry
    end
  end

  defp turn_boundary?(prev_entry, updated_entry) do
    Map.get(updated_entry, :turn_count, 0) > Map.get(prev_entry, :turn_count, 0)
  end

  defp assess_progress(entry, issue_id, update) do
    case Map.get(entry, :workspace_path) do
      workspace when is_binary(workspace) ->
        progress = Map.get(entry, :progress) || ProgressSignal.initial()
        marker = Map.get(progress, :dispatch_head)
        worker_host = Map.get(entry, :worker_host)
        timeout_ms = Config.progress_signal_git_timeout_ms()

        case Git.working_tree_signals(workspace, marker, worker_host, timeout_ms) do
          {:ok, signals} ->
            settings = Config.settings!()
            # Capture the dispatch marker lazily on the first probe; subsequent
            # turns count commits relative to it.
            dispatch_head = marker || signals.head

            observation = %{
              hash: signals.hash,
              empty: signals.empty,
              commits_since: signals.commits_since,
              error_sig: turn_error_signature(update),
              turn_count: Map.get(entry, :turn_count, 0)
            }

            advanced =
              progress
              |> ProgressSignal.advance(observation, settings)
              |> Map.put(:dispatch_head, dispatch_head)

            log_progress_assessment(entry, issue_id, advanced.assessment)
            Map.put(entry, :progress, advanced)

          {:error, reason} ->
            Logger.debug(
              "Progress probe failed; assessment unchanged issue_id=#{issue_id} " <>
                "issue_identifier=#{Map.get(entry, :identifier)} reason=#{inspect(reason)}"
            )

            entry
        end

      _no_workspace ->
        entry
    end
  end

  # Per-adapter terminal-error signature for a turn boundary. Clean boundaries
  # (`:turn_completed` / `:session_started`) carry no error, so this is normally
  # `nil` — terminal errors abort the run and surface via the DOWN reason rather
  # than as a worker update. The defensive claude clause captures an `error_code`
  # if a future envelope ever carries one at the boundary.
  defp turn_error_signature(%{agent_kind: :claude, payload: %{error_code: code}})
       when not is_nil(code),
       do: {:claude, code}

  defp turn_error_signature(_update), do: nil

  defp log_progress_assessment(entry, issue_id, assessment) do
    evidence = assessment.evidence

    message =
      "Progress assessment status=#{assessment.status} " <>
        "at_risk_no_commits=#{assessment.at_risk_no_commits} " <>
        "tree_streak=#{Map.get(evidence, :tree_hash_streak, 0)} " <>
        "commits_since=#{Map.get(evidence, :commits_since, 0)} " <>
        "error_sig=#{format_error_sig(Map.get(evidence, :error_sig))} " <>
        "turn=#{Map.get(evidence, :turn_count, 0)} " <>
        "issue_id=#{issue_id} issue_identifier=#{Map.get(entry, :identifier)} " <>
        "session_id=#{Map.get(entry, :session_id)}"

    # info when something warrants attention; debug otherwise to avoid one noisy
    # line per turn on a healthy session.
    if assessment.status != :progressing or assessment.at_risk_no_commits do
      Logger.info(message)
    else
      Logger.debug(message)
    end
  end

  defp format_error_sig(nil), do: "nil"
  defp format_error_sig({adapter, code}), do: "#{adapter}:#{code}"
  defp format_error_sig(other), do: inspect(other)

  # Last Layer-1 assessment for a running entry, for `snapshot/0` (dashboard +
  # `/api/v1/*`). Falls back to the neutral default before any turn lands.
  defp progress_assessment(metadata) do
    case Map.get(metadata, :progress) do
      %{assessment: assessment} -> assessment
      _ -> ProgressSignal.default_assessment()
    end
  end

  # Three event paths share the same envelope-level merge (last_event, pid,
  # session_id) but differ in how they touch the cumulative token totals:
  #
  # * `:token_usage`   — per-AssistantMessage live signal. Add the delta to
  #                      both `claude_*_tokens` and `claude_turn_provisional_*`.
  # * `:turn_completed`— authoritative ResultMessage rollup. Add the
  #                      *correction* `result.usage - turn_provisional` so the
  #                      running total ends at the authoritative value, then
  #                      reset turn_provisional. Correction is non-negative
  #                      (clamped to zero) so totals never move backwards if a
  #                      provisional already exceeded the rollup.
  # * everything else  — token totals untouched; only the envelope-level
  #                      bookkeeping moves forward.
  defp integrate_claude_update(running_entry, %{event: :token_usage} = update) do
    delta = extract_claude_token_delta(update)
    integrate_claude_envelope(running_entry, update, delta, &add_to_provisional/2)
  end

  defp integrate_claude_update(running_entry, %{event: :turn_completed} = update) do
    result_usage = extract_claude_token_delta(update)
    correction = compute_turn_correction(running_entry, result_usage)
    {entry, delta} = integrate_claude_envelope(running_entry, update, correction, &reset_provisional/1)
    # The turn is over; clear any in-flight tool count so a missed tool_finished
    # (e.g. a permission-denied tool with no PostToolUse) can't strand the entry
    # on the longer tool-stall window into the next turn.
    {Map.put(entry, :claude_tools_in_flight, 0), delta}
  end

  defp integrate_claude_update(running_entry, %{event: :tool_started} = update) do
    count = Map.get(running_entry, :claude_tools_in_flight, 0) + 1

    running_entry
    |> Map.put(:claude_tools_in_flight, count)
    |> integrate_claude_envelope(update, zero_token_delta(), &noop_provisional/1)
  end

  defp integrate_claude_update(running_entry, %{event: :tool_finished} = update) do
    count = max(Map.get(running_entry, :claude_tools_in_flight, 0) - 1, 0)

    running_entry
    |> Map.put(:claude_tools_in_flight, count)
    |> integrate_claude_envelope(update, zero_token_delta(), &noop_provisional/1)
  end

  defp integrate_claude_update(running_entry, update) do
    integrate_claude_envelope(running_entry, update, zero_token_delta(), &noop_provisional/1)
  end

  defp integrate_claude_envelope(running_entry, %{event: event, timestamp: timestamp} = update, token_delta, provisional_fn) do
    turn_count = Map.get(running_entry, :turn_count, 0)
    claude_app_server_pid = Map.get(running_entry, :claude_app_server_pid)

    base_merge = %{
      last_codex_timestamp: timestamp,
      # `:assistant_delta` is a per-token liveness ping — it refreshes the stall
      # timestamp but must not overwrite the dashboard's "last message"/event
      # cells with partial fragments, so preserve the prior values for it.
      last_codex_message:
        if(event == :assistant_delta,
          do: Map.get(running_entry, :last_codex_message),
          else: summarize_codex_update(update)
        ),
      session_id: session_id_for_update(running_entry.session_id, update),
      last_codex_event:
        if(event == :assistant_delta,
          do: Map.get(running_entry, :last_codex_event),
          else: event
        ),
      claude_app_server_pid: claude_app_server_pid_for_update(claude_app_server_pid, update),
      claude_input_tokens: Map.get(running_entry, :claude_input_tokens, 0) + token_delta.input_tokens,
      claude_output_tokens: Map.get(running_entry, :claude_output_tokens, 0) + token_delta.output_tokens,
      claude_total_tokens: Map.get(running_entry, :claude_total_tokens, 0) + token_delta.total_tokens,
      claude_cache_creation_input_tokens:
        Map.get(running_entry, :claude_cache_creation_input_tokens, 0) +
          token_delta.cache_creation_input_tokens,
      claude_cache_read_input_tokens:
        Map.get(running_entry, :claude_cache_read_input_tokens, 0) +
          token_delta.cache_read_input_tokens,
      turn_count: claude_turn_count_for_update(turn_count, update)
    }

    provisional_merge =
      case provisional_fn do
        fun when is_function(fun, 1) -> fun.(running_entry)
        fun when is_function(fun, 2) -> fun.(running_entry, token_delta)
      end

    {Map.merge(running_entry, Map.merge(base_merge, provisional_merge)), token_delta}
  end

  defp add_to_provisional(running_entry, delta) do
    %{
      claude_turn_provisional_input_tokens: Map.get(running_entry, :claude_turn_provisional_input_tokens, 0) + delta.input_tokens,
      claude_turn_provisional_output_tokens: Map.get(running_entry, :claude_turn_provisional_output_tokens, 0) + delta.output_tokens,
      claude_turn_provisional_total_tokens: Map.get(running_entry, :claude_turn_provisional_total_tokens, 0) + delta.total_tokens,
      claude_turn_provisional_cache_creation_input_tokens:
        Map.get(running_entry, :claude_turn_provisional_cache_creation_input_tokens, 0) +
          delta.cache_creation_input_tokens,
      claude_turn_provisional_cache_read_input_tokens:
        Map.get(running_entry, :claude_turn_provisional_cache_read_input_tokens, 0) +
          delta.cache_read_input_tokens
    }
  end

  defp reset_provisional(_running_entry) do
    %{
      claude_turn_provisional_input_tokens: 0,
      claude_turn_provisional_output_tokens: 0,
      claude_turn_provisional_total_tokens: 0,
      claude_turn_provisional_cache_creation_input_tokens: 0,
      claude_turn_provisional_cache_read_input_tokens: 0
    }
  end

  defp noop_provisional(_running_entry), do: %{}

  # `correction = max(0, ResultMessage.usage - turn_provisional)`. Clamping at
  # zero matters when a per-message stream already counted more than the
  # rollup (rare, but happens when AssistantMessage.usage races ahead of
  # ResultMessage in long turns); we never want the running total to move
  # backwards mid-flight.
  defp compute_turn_correction(running_entry, %{} = result_usage) do
    %{
      input_tokens: max(0, result_usage.input_tokens - Map.get(running_entry, :claude_turn_provisional_input_tokens, 0)),
      output_tokens: max(0, result_usage.output_tokens - Map.get(running_entry, :claude_turn_provisional_output_tokens, 0)),
      total_tokens: max(0, result_usage.total_tokens - Map.get(running_entry, :claude_turn_provisional_total_tokens, 0)),
      cache_creation_input_tokens:
        max(
          0,
          result_usage.cache_creation_input_tokens -
            Map.get(running_entry, :claude_turn_provisional_cache_creation_input_tokens, 0)
        ),
      cache_read_input_tokens:
        max(
          0,
          result_usage.cache_read_input_tokens -
            Map.get(running_entry, :claude_turn_provisional_cache_read_input_tokens, 0)
        ),
      seconds_running: 0
    }
  end

  defp zero_token_delta do
    %{
      input_tokens: 0,
      output_tokens: 0,
      total_tokens: 0,
      cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0,
      seconds_running: 0
    }
  end

  # Mirrors codex_app_server_pid_for_update/2 — Claude.AppServer stamps the
  # bash wrapper's os_pid as a string on every envelope, so once it lands we
  # keep it sticky for the remainder of the run.
  defp claude_app_server_pid_for_update(_existing, %{claude_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp claude_app_server_pid_for_update(_existing, %{claude_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp claude_app_server_pid_for_update(_existing, %{claude_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp claude_app_server_pid_for_update(existing, _update), do: existing

  # Claude advances `turn_count` on every `:turn_completed` event — there's no
  # `:session_started` analogue in the claude wire vocabulary. The codex path
  # uses `:session_started` as its tick.
  defp claude_turn_count_for_update(existing_count, %{event: :turn_completed})
       when is_integer(existing_count),
       do: existing_count + 1

  defp claude_turn_count_for_update(existing_count, _update) when is_integer(existing_count),
    do: existing_count

  defp claude_turn_count_for_update(_existing_count, _update), do: 0

  defp blocked_issue_state(%{issue: %Issue{state: state}}), do: state
  defp blocked_issue_state(_metadata), do: nil

  defp blocked_issue_url(%{issue: %Issue{url: url}}), do: url
  defp blocked_issue_url(_metadata), do: nil

  defp integrate_codex_update(running_entry, %{event: event, timestamp: timestamp} = update) do
    token_delta = extract_token_delta(running_entry, update)
    codex_input_tokens = Map.get(running_entry, :codex_input_tokens, 0)
    codex_output_tokens = Map.get(running_entry, :codex_output_tokens, 0)
    codex_total_tokens = Map.get(running_entry, :codex_total_tokens, 0)
    codex_app_server_pid = Map.get(running_entry, :codex_app_server_pid)
    last_reported_input = Map.get(running_entry, :codex_last_reported_input_tokens, 0)
    last_reported_output = Map.get(running_entry, :codex_last_reported_output_tokens, 0)
    last_reported_total = Map.get(running_entry, :codex_last_reported_total_tokens, 0)
    turn_count = Map.get(running_entry, :turn_count, 0)

    {
      Map.merge(running_entry, %{
        last_codex_timestamp: timestamp,
        last_codex_message: summarize_codex_update(update),
        session_id: session_id_for_update(running_entry.session_id, update),
        last_codex_event: event,
        codex_app_server_pid: codex_app_server_pid_for_update(codex_app_server_pid, update),
        codex_input_tokens: codex_input_tokens + token_delta.input_tokens,
        codex_output_tokens: codex_output_tokens + token_delta.output_tokens,
        codex_total_tokens: codex_total_tokens + token_delta.total_tokens,
        codex_last_reported_input_tokens: max(last_reported_input, token_delta.input_reported),
        codex_last_reported_output_tokens: max(last_reported_output, token_delta.output_reported),
        codex_last_reported_total_tokens: max(last_reported_total, token_delta.total_reported),
        turn_count: turn_count_for_update(turn_count, running_entry.session_id, update)
      }),
      token_delta
    }
  end

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_binary(pid),
       do: pid

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid})
       when is_integer(pid),
       do: Integer.to_string(pid)

  defp codex_app_server_pid_for_update(_existing, %{codex_app_server_pid: pid}) when is_list(pid),
    do: to_string(pid)

  defp codex_app_server_pid_for_update(existing, _update), do: existing

  defp session_id_for_update(_existing, %{session_id: session_id}) when is_binary(session_id),
    do: session_id

  defp session_id_for_update(existing, _update), do: existing

  defp turn_count_for_update(existing_count, existing_session_id, %{
         event: :session_started,
         session_id: session_id
       })
       when is_integer(existing_count) and is_binary(session_id) do
    if session_id == existing_session_id do
      existing_count
    else
      existing_count + 1
    end
  end

  defp turn_count_for_update(existing_count, _existing_session_id, _update)
       when is_integer(existing_count),
       do: existing_count

  defp turn_count_for_update(_existing_count, _existing_session_id, _update), do: 0

  defp summarize_codex_update(update) do
    %{
      event: update[:event],
      message: update[:payload] || update[:raw],
      timestamp: update[:timestamp],
      # Carry `agent_kind` so the dashboard renderer can pick the right
      # vocabulary (Claude events have a different shape than Codex's).
      agent_kind: update[:agent_kind]
    }
  end

  defp schedule_tick(%State{} = state, delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    if is_reference(state.tick_timer_ref) do
      Process.cancel_timer(state.tick_timer_ref)
    end

    tick_token = make_ref()
    timer_ref = Process.send_after(self(), {:tick, tick_token}, delay_ms)

    %{
      state
      | tick_timer_ref: timer_ref,
        tick_token: tick_token,
        next_poll_due_at_ms: System.monotonic_time(:millisecond) + delay_ms
    }
  end

  defp schedule_poll_cycle_start do
    :timer.send_after(@poll_transition_render_delay_ms, self(), :run_poll_cycle)
    :ok
  end

  defp next_poll_in_ms(nil, _now_ms), do: nil

  defp next_poll_in_ms(next_poll_due_at_ms, now_ms) when is_integer(next_poll_due_at_ms) do
    max(0, next_poll_due_at_ms - now_ms)
  end

  defp pop_running_entry(state, issue_id) do
    {Map.get(state.running, issue_id), %{state | running: Map.delete(state.running, issue_id)}}
  end

  defp record_session_completion_totals(state, running_entry) when is_map(running_entry) do
    runtime_seconds = running_seconds(running_entry.started_at, DateTime.utc_now())

    case Map.get(running_entry, :agent_kind) do
      :claude ->
        claude_totals =
          apply_claude_token_delta_map(state.claude_totals, %{seconds_running: runtime_seconds})

        %{state | claude_totals: claude_totals}

      _ ->
        codex_totals =
          apply_token_delta(
            state.codex_totals,
            %{
              input_tokens: 0,
              output_tokens: 0,
              total_tokens: 0,
              seconds_running: runtime_seconds
            }
          )

        %{state | codex_totals: codex_totals}
    end
  end

  defp record_session_completion_totals(state, _running_entry), do: state

  defp refresh_runtime_config(%State{} = state) do
    config = Config.settings!()

    %{
      state
      | poll_interval_ms: config.polling.interval_ms,
        max_concurrent_agents: config.agent.max_concurrent_agents
    }
  end

  defp retry_candidate_issue?(%Issue{} = issue, terminal_states) do
    candidate_issue?(issue, active_state_set(), terminal_states) and
      !issue_blocked_by_non_terminal?(issue, terminal_states)
  end

  defp dispatch_slots_available?(%Issue{} = issue, %State{} = state) do
    available_slots(state) > 0 and state_slots_available?(issue, state.running) and
      active_provider_quota_allows_dispatch(state) == :ok
  end

  defp active_provider_quota_allows_dispatch(%State{} = state) do
    config = Config.settings!()
    provider = active_provider(config)
    quota = provider_quota_config(config, provider)

    # The pause gate is opt-in per provider (`quota.enabled`). Quota tracking and
    # dashboard display stay on regardless — only the dispatch-pause action is
    # gated, so enabling it never changes how usage is surfaced.
    if quota_pause_enabled?(quota) do
      threshold = dispatch_pause_percent(quota)
      snapshot = state.provider_quotas |> ensure_provider_quotas() |> Map.get(provider)
      now_ms = System.monotonic_time(:millisecond)

      if ProviderQuota.active_quota_exhausted?(snapshot, threshold, now_ms) do
        {:paused, provider, threshold}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp quota_pause_enabled?(%{enabled: true}), do: true
  defp quota_pause_enabled?(_quota), do: false

  defp active_provider(%{agent: %{kind: "claude"}}), do: :claude
  defp active_provider(_config), do: :codex

  @default_dispatch_pause_percent 95.0

  defp dispatch_pause_percent(%{dispatch_pause_percent: value}) when is_number(value), do: value
  defp dispatch_pause_percent(_quota), do: @default_dispatch_pause_percent

  # Codex quota lives at the canonical top-level `codex` block (kept in sync
  # with `agent.codex` by the schema's legacy alias); Claude quota lives under
  # `agent.claude`.
  defp provider_quota_config(%{codex: %{quota: %{} = quota}}, :codex), do: quota
  defp provider_quota_config(%{agent: %{claude: %{quota: %{} = quota}}}, :claude), do: quota
  defp provider_quota_config(_config, _provider), do: nil

  defp apply_codex_token_delta(
         %{codex_totals: codex_totals} = state,
         %{input_tokens: input, output_tokens: output, total_tokens: total} = token_delta
       )
       when is_integer(input) and is_integer(output) and is_integer(total) do
    %{state | codex_totals: apply_token_delta(codex_totals, token_delta)}
  end

  defp apply_codex_token_delta(state, _token_delta), do: state

  defp apply_claude_token_delta(%{claude_totals: claude_totals} = state, %{} = token_delta) do
    %{state | claude_totals: apply_claude_token_delta_map(claude_totals, token_delta)}
  end

  defp apply_claude_token_delta_map(claude_totals, token_delta) do
    %{
      input_tokens: bump(claude_totals, :input_tokens, token_delta),
      output_tokens: bump(claude_totals, :output_tokens, token_delta),
      total_tokens: bump(claude_totals, :total_tokens, token_delta),
      cache_creation_input_tokens: bump(claude_totals, :cache_creation_input_tokens, token_delta),
      cache_read_input_tokens: bump(claude_totals, :cache_read_input_tokens, token_delta),
      seconds_running: bump(claude_totals, :seconds_running, token_delta)
    }
  end

  defp bump(totals, key, delta) do
    max(0, Map.get(totals, key, 0) + Map.get(delta, key, 0))
  end

  defp apply_codex_rate_limits(%State{} = state, update) when is_map(update) do
    case extract_rate_limits(update) do
      %{} = rate_limits ->
        snapshot = ProviderQuota.normalize_codex(rate_limits, stale_after_ms: codex_quota_stale_after_ms())

        provider_quotas =
          state.provider_quotas
          |> ensure_provider_quotas()
          |> Map.put(:codex, snapshot)

        %{state | provider_quotas: provider_quotas}

      _ ->
        state
    end
  end

  defp apply_codex_rate_limits(state, _update), do: state

  defp codex_quota_stale_after_ms do
    case provider_quota_config(Config.settings!(), :codex) do
      %{stale_after_ms: ms} when is_integer(ms) and ms > 0 -> ms
      _ -> 180_000
    end
  end

  defp apply_token_delta(codex_totals, token_delta) do
    input_tokens = Map.get(codex_totals, :input_tokens, 0) + token_delta.input_tokens
    output_tokens = Map.get(codex_totals, :output_tokens, 0) + token_delta.output_tokens
    total_tokens = Map.get(codex_totals, :total_tokens, 0) + token_delta.total_tokens

    seconds_running =
      Map.get(codex_totals, :seconds_running, 0) + Map.get(token_delta, :seconds_running, 0)

    %{
      input_tokens: max(0, input_tokens),
      output_tokens: max(0, output_tokens),
      total_tokens: max(0, total_tokens),
      seconds_running: max(0, seconds_running)
    }
  end

  # The claude `turn_end` envelope's `usage` map is already a per-turn delta
  # (per Anthropic SDK semantics), so accumulators just add it directly. No
  # cumulative→delta diffing needed; no `claude_last_reported_*` bookkeeping.
  # `total_tokens = input + output` (codex parity); cache counts are siblings
  # and never folded into `total_tokens`.
  defp extract_claude_token_delta(%{} = update) do
    usage =
      case update do
        %{payload: %{usage: %{} = u}} -> u
        %{payload: %{"usage" => %{} = u}} -> u
        _ -> %{}
      end

    input = nonnegative_integer_or_zero(usage, [:input_tokens, "input_tokens"])
    output = nonnegative_integer_or_zero(usage, [:output_tokens, "output_tokens"])

    cache_creation =
      nonnegative_integer_or_zero(usage, [
        :cache_creation_input_tokens,
        "cache_creation_input_tokens"
      ])

    cache_read =
      nonnegative_integer_or_zero(usage, [:cache_read_input_tokens, "cache_read_input_tokens"])

    %{
      input_tokens: input,
      output_tokens: output,
      total_tokens: input + output,
      cache_creation_input_tokens: cache_creation,
      cache_read_input_tokens: cache_read,
      seconds_running: 0
    }
  end

  defp nonnegative_integer_or_zero(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, 0, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _ -> nil
      end
    end)
  end

  defp extract_token_delta(running_entry, %{event: _, timestamp: _} = update) do
    running_entry = running_entry || %{}
    usage = extract_token_usage(update)

    {
      compute_token_delta(
        running_entry,
        :input,
        usage,
        :codex_last_reported_input_tokens
      ),
      compute_token_delta(
        running_entry,
        :output,
        usage,
        :codex_last_reported_output_tokens
      ),
      compute_token_delta(
        running_entry,
        :total,
        usage,
        :codex_last_reported_total_tokens
      )
    }
    |> Tuple.to_list()
    |> then(fn [input, output, total] ->
      %{
        input_tokens: input.delta,
        output_tokens: output.delta,
        total_tokens: total.delta,
        input_reported: input.reported,
        output_reported: output.reported,
        total_reported: total.reported
      }
    end)
  end

  defp compute_token_delta(running_entry, token_key, usage, reported_key) do
    next_total = get_token_usage(usage, token_key)
    prev_reported = Map.get(running_entry, reported_key, 0)

    delta =
      if is_integer(next_total) and next_total >= prev_reported do
        next_total - prev_reported
      else
        0
      end

    %{
      delta: max(delta, 0),
      reported: if(is_integer(next_total), do: next_total, else: prev_reported)
    }
  end

  defp extract_token_usage(update) do
    payloads = [
      update[:usage],
      Map.get(update, "usage"),
      Map.get(update, :usage),
      update[:payload],
      Map.get(update, "payload"),
      update
    ]

    Enum.find_value(payloads, &absolute_token_usage_from_payload/1) ||
      Enum.find_value(payloads, &turn_completed_usage_from_payload/1) ||
      %{}
  end

  defp extract_rate_limits(update) do
    rate_limits_from_payload(update[:rate_limits]) ||
      rate_limits_from_payload(Map.get(update, "rate_limits")) ||
      rate_limits_from_payload(Map.get(update, :rate_limits)) ||
      rate_limits_from_payload(update[:payload]) ||
      rate_limits_from_payload(Map.get(update, "payload")) ||
      rate_limits_from_payload(update)
  end

  defp ensure_provider_quotas(%{} = provider_quotas) do
    provider_quotas
    |> Map.put_new(:codex, nil)
    |> Map.put_new(:claude, nil)
  end

  defp ensure_provider_quotas(_provider_quotas), do: %{codex: nil, claude: nil}

  # The Codex rate-limit view exposed in the status snapshot is the raw payload
  # carried on the normalized Codex quota snapshot, so the two can't drift.
  defp codex_raw_rate_limits(provider_quotas) do
    case provider_quotas |> ensure_provider_quotas() |> Map.get(:codex) do
      %{raw: %{} = raw} -> raw
      _ -> nil
    end
  end

  defp absolute_token_usage_from_payload(payload) when is_map(payload) do
    absolute_paths = [
      ["params", "msg", "payload", "info", "total_token_usage"],
      [:params, :msg, :payload, :info, :total_token_usage],
      ["params", "msg", "info", "total_token_usage"],
      [:params, :msg, :info, :total_token_usage],
      ["params", "tokenUsage", "total"],
      [:params, :tokenUsage, :total],
      ["tokenUsage", "total"],
      [:tokenUsage, :total]
    ]

    explicit_map_at_paths(payload, absolute_paths)
  end

  defp absolute_token_usage_from_payload(_payload), do: nil

  defp turn_completed_usage_from_payload(payload) when is_map(payload) do
    method = Map.get(payload, "method") || Map.get(payload, :method)

    if method in ["turn/completed", :turn_completed] do
      direct =
        Map.get(payload, "usage") ||
          Map.get(payload, :usage) ||
          map_at_path(payload, ["params", "usage"]) ||
          map_at_path(payload, [:params, :usage])

      if is_map(direct) and integer_token_map?(direct), do: direct
    end
  end

  defp turn_completed_usage_from_payload(_payload), do: nil

  defp rate_limits_from_payload(payload) when is_map(payload) do
    direct = Map.get(payload, "rate_limits") || Map.get(payload, :rate_limits)

    cond do
      codex_rate_limits_response_map?(payload) ->
        payload

      codex_rate_limits_response_map?(direct) ->
        direct

      rate_limits_map?(direct) ->
        direct

      rate_limits_map?(payload) ->
        payload

      true ->
        rate_limit_payloads(payload)
    end
  end

  defp rate_limits_from_payload(payload) when is_list(payload) do
    rate_limit_payloads(payload)
  end

  defp rate_limits_from_payload(_payload), do: nil

  defp codex_rate_limits_response_map?(payload) when is_map(payload) do
    is_map(Map.get(payload, "rateLimitsByLimitId")) or is_map(Map.get(payload, :rateLimitsByLimitId)) or
      is_map(Map.get(payload, "rateLimits")) or is_map(Map.get(payload, :rateLimits))
  end

  defp codex_rate_limits_response_map?(_payload), do: false

  defp rate_limit_payloads(payload) when is_map(payload) do
    Map.values(payload)
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limit_payloads(payload) when is_list(payload) do
    payload
    |> Enum.reduce_while(nil, fn
      value, nil ->
        case rate_limits_from_payload(value) do
          nil -> {:cont, nil}
          rate_limits -> {:halt, rate_limits}
        end

      _value, result ->
        {:halt, result}
    end)
  end

  defp rate_limits_map?(payload) when is_map(payload) do
    limit_id =
      Map.get(payload, "limit_id") ||
        Map.get(payload, :limit_id) ||
        Map.get(payload, "limit_name") ||
        Map.get(payload, :limit_name)

    has_buckets =
      Enum.any?(
        ["primary", :primary, "secondary", :secondary, "credits", :credits],
        &Map.has_key?(payload, &1)
      )

    !is_nil(limit_id) and has_buckets
  end

  defp rate_limits_map?(_payload), do: false

  defp explicit_map_at_paths(payload, paths) when is_map(payload) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      value = map_at_path(payload, path)

      if is_map(value) and integer_token_map?(value), do: value
    end)
  end

  defp explicit_map_at_paths(_payload, _paths), do: nil

  defp map_at_path(payload, path) when is_map(payload) and is_list(path) do
    Enum.reduce_while(path, payload, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, nil}
      end
    end)
  end

  defp map_at_path(_payload, _path), do: nil

  defp integer_token_map?(payload) do
    token_fields = [
      :input_tokens,
      :output_tokens,
      :total_tokens,
      :prompt_tokens,
      :completion_tokens,
      :inputTokens,
      :outputTokens,
      :totalTokens,
      :promptTokens,
      :completionTokens,
      "input_tokens",
      "output_tokens",
      "total_tokens",
      "prompt_tokens",
      "completion_tokens",
      "inputTokens",
      "outputTokens",
      "totalTokens",
      "promptTokens",
      "completionTokens"
    ]

    token_fields
    |> Enum.any?(fn field ->
      value = payload_get(payload, field)
      !is_nil(integer_like(value))
    end)
  end

  defp get_token_usage(usage, :input),
    do:
      payload_get(usage, [
        "input_tokens",
        "prompt_tokens",
        :input_tokens,
        :prompt_tokens,
        :input,
        "promptTokens",
        :promptTokens,
        "inputTokens",
        :inputTokens
      ])

  defp get_token_usage(usage, :output),
    do:
      payload_get(usage, [
        "output_tokens",
        "completion_tokens",
        :output_tokens,
        :completion_tokens,
        :output,
        :completion,
        "outputTokens",
        :outputTokens,
        "completionTokens",
        :completionTokens
      ])

  defp get_token_usage(usage, :total),
    do:
      payload_get(usage, [
        "total_tokens",
        "total",
        :total_tokens,
        :total,
        "totalTokens",
        :totalTokens
      ])

  defp payload_get(payload, fields) when is_list(fields) do
    Enum.find_value(fields, fn field -> map_integer_value(payload, field) end)
  end

  defp payload_get(payload, field), do: map_integer_value(payload, field)

  defp map_integer_value(payload, field) do
    if is_map(payload) do
      value = Map.get(payload, field)
      integer_like(value)
    else
      nil
    end
  end

  defp running_seconds(%DateTime{} = started_at, %DateTime{} = now) do
    max(0, DateTime.diff(now, started_at, :second))
  end

  defp running_seconds(_started_at, _now), do: 0

  defp integer_like(value) when is_integer(value) and value >= 0, do: value

  defp integer_like(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {num, _} when num >= 0 -> num
      _ -> nil
    end
  end

  defp integer_like(_value), do: nil
end
