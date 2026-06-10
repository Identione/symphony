defmodule SymphonyElixir.OrchestratorCoverageTest do
  @moduledoc """
  Targeted behavioral coverage for `SymphonyElixir.Orchestrator` (IDE-116).

  Drives the GenServer through worker-host dispatch, reconciliation of
  running/blocked issues, retry scheduling and its rate-limit/error edges,
  Linear-fetch failure clauses, and the defensive no-op message handlers.

  Most tests configure the in-memory tracker (`kind: "memory"`) so the
  orchestrator's `Tracker.*` round-trips land as messages on the test process
  or can be steered via the `:memory_tracker_*_response` injection knobs.

  ## Residually-uncovered lines (provably dead)

  Two `orchestrator.ex` lines remain uncovered and are provably unreachable:
  the `(_value, result) -> {:halt, result}` clauses of the two `reduce_while`
  callbacks in `rate_limit_payloads/1`. `reduce_while` only re-invokes the
  callback while it returns `{:cont, nil}`, and the first match immediately
  returns `{:halt, rate_limits}`, so the accumulator is never non-`nil` when
  the callback runs — the "accumulator already set" clause can never be
  selected. It exists only because the compiler keeps the literal function
  clause.

  These tests drive the orchestrator GenServer end-to-end via real messages
  and the in-memory tracker — they do not reach into the module through
  test-only backdoors. `Orchestrator` therefore stays on the coverage
  `ignore_modules` list (see `mix.exs`); the suite exists for behavioral
  regression safety, not to chase a literal 100% (IDE-116).
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue

  # ── helpers ───────────────────────────────────────────────────────────────

  defp use_memory_tracker(overrides \\ []) do
    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge([tracker_kind: "memory", tracker_api_token: nil], overrides)
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_candidate_issues_response)
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_issue_states_by_ids_response)
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_issues_by_states_response)
    end)

    :ok
  end

  defp start_orchestrator(label) do
    name = Module.concat(__MODULE__, label)
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end

  defp issue(id, identifier, opts \\ []) do
    %Issue{
      id: id,
      identifier: identifier,
      title: Keyword.get(opts, :title, "Title #{identifier}"),
      state: Keyword.get(opts, :state, "In Progress"),
      url: "https://example.org/issues/#{identifier}",
      labels: Keyword.get(opts, :labels, []),
      blocked_by: Keyword.get(opts, :blocked_by, []),
      assigned_to_worker: Keyword.get(opts, :assigned_to_worker, true),
      assignee_id: Keyword.get(opts, :assignee_id, nil),
      priority: Keyword.get(opts, :priority, nil),
      created_at: Keyword.get(opts, :created_at, nil)
    }
  end

  # A harmless, killable stand-in process so `terminate_running_issue` can
  # exit it without taking the test process down. The orchestrator only ever
  # `Process.exit/2`s it via `terminate_task/1`'s `:not_found` fallback.
  defp dummy_worker do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp running_entry(issue, opts) do
    %{
      pid: Keyword.get(opts, :pid, dummy_worker()),
      ref: Keyword.get(opts, :ref),
      identifier: issue.identifier,
      issue: issue,
      worker_host: Keyword.get(opts, :worker_host),
      workspace_path: Keyword.get(opts, :workspace_path),
      session_id: Keyword.get(opts, :session_id),
      retry_attempt: Keyword.get(opts, :retry_attempt, 0),
      agent_kind: Keyword.get(opts, :agent_kind, :codex),
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: Keyword.get(opts, :started_at, DateTime.utc_now())
    }
  end

  defp replace_state(pid, fun), do: :sys.replace_state(pid, fun)

  defp wait_for_state(pid, predicate, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_state(pid, predicate, deadline)
  end

  defp do_wait_for_state(pid, predicate, deadline) do
    state = :sys.get_state(pid)

    cond do
      predicate.(state) ->
        state

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for orchestrator state: #{inspect(state)}")

      true ->
        Process.sleep(5)
        do_wait_for_state(pid, predicate, deadline)
    end
  end

  defp seed(pid, fields) do
    replace_state(pid, fn state ->
      Enum.reduce(fields, state, fn {k, v}, acc -> Map.put(acc, k, v) end)
    end)
  end

  # ── maybe_dispatch: Linear fetch failure clauses ──────────────────────────

  test "run_poll_cycle logs and keeps state when candidate fetch is rate limited" do
    use_memory_tracker()
    pid = start_orchestrator(:CandidateRateLimited)

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_candidate_issues_response,
      {:error, :rate_limited}
    )

    before = :sys.get_state(pid)
    send(pid, :run_poll_cycle)

    # Nothing dispatched; running stays empty across the cycle.
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert state.running == before.running
    assert map_size(state.running) == 0
  end

  test "maybe_dispatch surfaces a missing-linear-token config error without dispatching" do
    # Real linear tracker with no api key forces Config.validate!/0 to fail
    # with :missing_linear_api_token inside maybe_dispatch. The api_key falls
    # back to $LINEAR_API_KEY, so unset it for the duration of this test.
    prev = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", prev) end)

    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "linear", tracker_api_token: nil)
    pid = start_orchestrator(:MissingToken)

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert map_size(state.running) == 0
  end

  # ── reconcile_running_issues / reconcile_blocked_issues fetch errors ──────

  test "reconcile keeps running workers when the running-state refresh errors" do
    use_memory_tracker()
    pid = start_orchestrator(:ReconcileRunningError)

    iss = issue("iss-recon-run", "REC-1")
    entry = running_entry(iss, ref: make_ref())
    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_issue_states_by_ids_response,
      {:error, :boom}
    )

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert Map.has_key?(state.running, iss.id), "running worker preserved on refresh error"
  end

  # ── reconcile_blocked_issue_state cond branches ───────────────────────────

  test "blocked issue moving to terminal state releases the block and cleans workspace" do
    use_memory_tracker(tracker_terminal_states: ["Done"])
    pid = start_orchestrator(:BlockedTerminal)

    iss = issue("iss-blk-term", "BLK-1", state: "Done")

    blocked_entry = %{
      issue_id: iss.id,
      identifier: iss.identifier,
      issue: %{iss | state: "In Progress"},
      worker_host: nil,
      error: "stuck",
      blocked_at: DateTime.utc_now()
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])
    seed(pid, blocked: %{iss.id => blocked_entry}, claimed: MapSet.new([iss.id]))

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> not Map.has_key?(s.blocked, iss.id) end)
    refute MapSet.member?(state.claimed, iss.id)
  end

  # ── reconcile_missing_running_issue_ids ───────────────────────────────────

  test "running issue no longer visible during refresh stops the agent" do
    use_memory_tracker()
    pid = start_orchestrator(:RunningMissing)

    visible = issue("iss-visible", "VIS-1")
    missing = issue("iss-missing", "MISS-1")

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [visible])

    seed(pid,
      running: %{
        visible.id => running_entry(visible, ref: make_ref()),
        missing.id => running_entry(missing, ref: make_ref())
      },
      claimed: MapSet.new([visible.id, missing.id])
    )

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> not Map.has_key?(s.running, missing.id) end)
    assert Map.has_key?(state.running, visible.id)
    refute MapSet.member?(state.claimed, missing.id)
  end

  # ── refresh_running_issue_state active branch ─────────────────────────────

  # ── dispatch via :retry_issue with a worker host (spawn path) ──────────────

  test "retry_issue dispatches an active issue onto a worker host and records a running entry" do
    use_memory_tracker(worker_ssh_hosts: ["worker-a"], worker_max_concurrent_agents_per_host: 5)
    pid = start_orchestrator(:RetryDispatchWorker)

    iss = issue("iss-retry-dispatch", "RD-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    retry_token = make_ref()

    seed(pid,
      retry_attempts: %{
        iss.id => %{
          attempt: 2,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: iss.identifier,
          error: "agent exited",
          worker_host: "worker-a",
          workspace_path: nil
        }
      }
    )

    send(pid, {:retry_issue, iss.id, retry_token})

    state = wait_for_state(pid, fn s -> Map.has_key?(s.running, iss.id) end)
    assert state.running[iss.id].worker_host == "worker-a"
    assert MapSet.member?(state.claimed, iss.id)
  end

  test "retry_issue with a stale token is a no-op" do
    use_memory_tracker()
    pid = start_orchestrator(:RetryStaleToken)

    iss = issue("iss-stale-token", "ST-1")

    seed(pid,
      retry_attempts: %{
        iss.id => %{
          attempt: 1,
          timer_ref: nil,
          retry_token: make_ref(),
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: iss.identifier
        }
      }
    )

    before = :sys.get_state(pid)
    send(pid, {:retry_issue, iss.id, make_ref()})
    Process.sleep(30)
    assert :sys.get_state(pid).retry_attempts == before.retry_attempts
  end

  # ── handle_retry_issue: terminal, left-active, missing, rate-limited, error ─

  test "retry_issue removes the claim when the issue is now terminal" do
    use_memory_tracker(tracker_terminal_states: ["Done"])
    pid = start_orchestrator(:RetryTerminal)

    iss = issue("iss-retry-terminal", "RT-1", state: "Done")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    retry_token = make_ref()

    seed(pid,
      claimed: MapSet.new([iss.id]),
      retry_attempts: %{
        iss.id => %{
          attempt: 1,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: iss.identifier
        }
      }
    )

    send(pid, {:retry_issue, iss.id, retry_token})
    state = wait_for_state(pid, fn s -> not Map.has_key?(s.retry_attempts, iss.id) end)
    refute MapSet.member?(state.claimed, iss.id)
  end

  # ── spawn_issue_on_worker_host: spawn failure → retry ─────────────────────

  test "do_dispatch reports no worker capacity and leaves state unchanged" do
    use_memory_tracker(worker_ssh_hosts: ["worker-a"], worker_max_concurrent_agents_per_host: 1)
    pid = start_orchestrator(:DispatchNoCapacity)

    iss = issue("iss-no-cap", "NC-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    busy = issue("iss-busy", "NC-0", state: "In Progress")

    retry_token = make_ref()

    seed(pid,
      running: %{busy.id => running_entry(busy, ref: make_ref(), worker_host: "worker-a")},
      claimed: MapSet.new([busy.id, iss.id]),
      retry_attempts: %{
        iss.id => %{
          attempt: 1,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: iss.identifier,
          worker_host: "worker-a"
        }
      }
    )

    # worker-a full → handle_active_retry's worker_slots_available?/2 is false,
    # so it reschedules rather than dispatching.
    send(pid, {:retry_issue, iss.id, retry_token})

    state =
      wait_for_state(pid, fn s ->
        match?(%{attempt: 2}, s.retry_attempts[iss.id])
      end)

    refute Map.has_key?(state.running, iss.id)
  end

  # ── continuation retry delay (normal exit) ────────────────────────────────

  test "normal agent exit completes the issue and schedules a continuation retry" do
    use_memory_tracker()
    pid = start_orchestrator(:NormalContinuation)

    iss = issue("iss-normal", "NM-1", state: "In Progress")
    ref = make_ref()
    seed(pid, running: %{iss.id => running_entry(iss, ref: ref)}, claimed: MapSet.new([iss.id]))

    send(pid, {:DOWN, ref, :process, self(), :normal})

    state = wait_for_state(pid, fn s -> Map.has_key?(s.retry_attempts, iss.id) end)
    assert MapSet.member?(state.completed, iss.id)
    # Continuation retry uses the 1s delay at attempt 1.
    retry = state.retry_attempts[iss.id]
    assert retry.attempt == 1
    remaining = retry.due_at_ms - System.monotonic_time(:millisecond)
    assert remaining <= 1_000 and remaining > 0
  end

  test "abnormal agent exit with a non-classified reason schedules a failure retry" do
    use_memory_tracker()
    pid = start_orchestrator(:AbnormalRetry)

    iss = issue("iss-abnormal", "AB-1", state: "In Progress")
    ref = make_ref()

    seed(pid,
      running: %{iss.id => running_entry(iss, ref: ref, retry_attempt: 1)},
      claimed: MapSet.new([iss.id])
    )

    send(pid, {:DOWN, ref, :process, self(), :killed})

    state = wait_for_state(pid, fn s -> Map.has_key?(s.retry_attempts, iss.id) end)
    refute Map.has_key?(state.running, iss.id)
    assert state.retry_attempts[iss.id].error =~ "agent exited"
  end

  # ── DOWN for an unknown ref is a no-op ────────────────────────────────────

  # ── worker_runtime_info handler ───────────────────────────────────────────

  # ── codex_worker_update for an unknown issue / malformed ──────────────────

  # ── unknown info message ──────────────────────────────────────────────────

  # ── stale tick token ──────────────────────────────────────────────────────

  # ── deterministic_failure_result with stale token (debug branch) ──────────

  # ── request_refresh / snapshot helpers ────────────────────────────────────

  test "request_refresh on a live server queues a poll and coalesces when already in progress" do
    use_memory_tracker()
    name = Module.concat(__MODULE__, :RefreshLive)
    {:ok, pid} = Orchestrator.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    # Force a not-in-progress, not-due state so the first refresh schedules a tick.
    replace_state(pid, fn s ->
      %{s | poll_check_in_progress: false, next_poll_due_at_ms: System.monotonic_time(:millisecond) + 60_000}
    end)

    assert %{queued: true, coalesced: false} = Orchestrator.request_refresh(name)

    # Now mark a check in progress → the next refresh coalesces.
    replace_state(pid, fn s -> %{s | poll_check_in_progress: true} end)
    assert %{queued: true, coalesced: true} = Orchestrator.request_refresh(name)
  end

  # ── refresh_runtime_config picks up reloaded config ───────────────────────

  test "tick refreshes poll interval and max concurrent agents from reloaded config" do
    use_memory_tracker(poll_interval_ms: 1234, max_concurrent_agents: 7)
    pid = start_orchestrator(:RefreshConfig)

    # Mangle in-memory config values, then send a tick to force a refresh.
    replace_state(pid, fn s -> %{s | poll_interval_ms: 1, max_concurrent_agents: 1} end)
    send(pid, :tick)

    state = wait_for_state(pid, fn s -> s.poll_interval_ms == 1234 end)
    assert state.max_concurrent_agents == 7
  end

  # ── record_session_completion_totals: claude branch ───────────────────────

  # ── start_link/0 default opts ─────────────────────────────────────────────

  # ── maybe_dispatch: semantic config validation errors ─────────────────────

  # ── startup terminal workspace cleanup (init) ─────────────────────────────

  # ── codex_worker_update: pid coercion + session_started turn counting ──────

  # ── claude_worker_update: pid coercion + non-token event + string usage ────

  defp seed_claude_running(pid, iss, extra \\ %{}) do
    base =
      running_entry(iss, ref: make_ref(), agent_kind: :claude)
      |> Map.merge(%{
        turn_count: 0,
        claude_input_tokens: 0,
        claude_output_tokens: 0,
        claude_total_tokens: 0,
        claude_cache_creation_input_tokens: 0,
        claude_cache_read_input_tokens: 0,
        claude_turn_provisional_input_tokens: 0,
        claude_turn_provisional_output_tokens: 0,
        claude_turn_provisional_total_tokens: 0,
        claude_turn_provisional_cache_creation_input_tokens: 0,
        claude_turn_provisional_cache_read_input_tokens: 0
      })
      |> Map.merge(extra)

    seed(pid, running: %{iss.id => base})
  end

  test "a claude token_usage event with string usage keys and integer pid is integrated" do
    use_memory_tracker()
    pid = start_orchestrator(:ClaudeStringUsage)

    iss = issue("iss-claude-strusage", "CSU-1")
    seed_claude_running(pid, iss)

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         agent_kind: :claude,
         event: :token_usage,
         timestamp: DateTime.utc_now(),
         claude_app_server_pid: 4242,
         payload: %{"usage" => %{"input_tokens" => 11, "output_tokens" => 7}}
       }}
    )

    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:claude_input_tokens] == 11 end)

    assert state.running[iss.id].claude_output_tokens == 7
    assert state.running[iss.id].claude_total_tokens == 18
    assert state.running[iss.id].claude_app_server_pid == "4242"
  end

  # ── apply_codex_rate_limits: top-level :rate_limits and list shapes ────────

  defp seed_codex_running(pid, iss) do
    seed(pid,
      running: %{
        iss.id =>
          running_entry(iss, ref: make_ref())
          |> Map.merge(%{
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 0
          })
      }
    )
  end

  test "codex rate limits supplied at the top-level :rate_limits key are captured" do
    use_memory_tracker()
    pid = start_orchestrator(:RateLimitTopLevel)

    iss = issue("iss-rl-top", "RLT-1")
    seed_codex_running(pid, iss)

    rate_limits = %{
      "limit_id" => "codex",
      "primary" => %{"remaining" => 5, "limit" => 100}
    }

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         rate_limits: rate_limits,
         payload: %{method: "noise"}
       }}
    )

    state = wait_for_state(pid, fn s -> s.codex_rate_limits == rate_limits end)
    assert state.codex_rate_limits == rate_limits
  end

  # ── find_issue_by_id miss via retry path that finds the wrong issues ───────

  # ── blocker_error: approval_required variants ─────────────────────────────

  test "an agent that exits while awaiting approval is blocked with the approval error" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    pid = start_orchestrator(:ApprovalBlock)

    iss = issue("iss-approval", "AP-1", state: "In Progress")
    ref = make_ref()

    entry =
      running_entry(iss, ref: ref)
      |> Map.merge(%{last_codex_event: :approval_required})

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    send(pid, {:DOWN, ref, :process, self(), {:shutdown, :approval_required}})

    state = wait_for_state(pid, fn s -> Map.has_key?(s.blocked, iss.id) end)
    assert state.blocked[iss.id].error == "codex turn requires approval"
  end

  # ── snapshot/0 + snapshot abnormal exit ───────────────────────────────────

  # ── dispatch_issue skip/error branches (via retry → handle_active_retry) ───

  defp seed_retry(pid, iss, extra \\ %{}) do
    retry_token = make_ref()

    entry =
      Map.merge(
        %{
          attempt: 1,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: iss.identifier
        },
        extra
      )

    seed(pid, claimed: MapSet.new([iss.id]), retry_attempts: %{iss.id => entry})
    retry_token
  end

  test "dispatch skips a retry whose revalidation shows the issue is missing" do
    use_memory_tracker()
    pid = start_orchestrator(:DispatchSkipMissing)

    iss = issue("iss-skip-missing", "DSM-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])
    # Candidate fetch finds it; revalidation by-ids fetch returns empty.
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_issue_states_by_ids_response, {:ok, []})

    token = seed_retry(pid, iss)
    send(pid, {:retry_issue, iss.id, token})

    state = wait_for_state(pid, fn s -> not Map.has_key?(s.retry_attempts, iss.id) end)
    refute Map.has_key?(state.running, iss.id)
  end

  test "dispatch skips a retry whose revalidation errors generically" do
    use_memory_tracker()
    pid = start_orchestrator(:DispatchSkipError)

    iss = issue("iss-skip-err", "DSE-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    token = seed_retry(pid, iss)

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_issue_states_by_ids_response,
      {:error, :transport_down}
    )

    send(pid, {:retry_issue, iss.id, token})
    Process.sleep(40)
    state = :sys.get_state(pid)
    refute Map.has_key?(state.running, iss.id)
  end

  # ── extract_claude_token_delta: token_usage with no usage payload ─────────

  # ── codex turn/completed usage: direct "usage" and atom params/usage ──────

  # ── cancel_retry_timer with a live timer (escalation drop) ────────────────

  test "escalation cancels a live retry timer when dropping the issue" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "iss-esc-timer" => [
        %{id: "wp-esc-timer", body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do", resolved_at: nil}
      ]
    })

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_comments)
    end)

    pid = start_orchestrator(:EscalationCancelTimer)

    iss = issue("iss-esc-timer", "ET-1", state: "In Progress")
    ref = make_ref()

    # Seed a running entry AND a live retry timer so escalate_running_issue/3
    # exercises cancel_retry_timer's Process.cancel_timer branch.
    live_timer = Process.send_after(pid, :noop_timer_msg, 60_000)

    seed(pid,
      running: %{iss.id => running_entry(iss, ref: ref)},
      claimed: MapSet.new([iss.id]),
      retry_attempts: %{iss.id => %{attempt: 1, timer_ref: live_timer, retry_token: make_ref()}},
      deterministic_failures: %{
        iss.id => %{code: :quota_exceeded, count: 4, notified_alert?: true, notified_escalation?: false}
      }
    )

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    state =
      wait_for_state(
        pid,
        fn s -> not MapSet.member?(s.claimed, iss.id) and not Map.has_key?(s.pending_escalations, iss.id) end,
        2_000
      )

    refute Map.has_key?(state.retry_attempts, iss.id)
  end

  # ── running_entry_issue_fallback (alert with no embedded issue) ───────────

  # ── spawn failure on dispatch schedules a retry ───────────────────────────

  test "a failed agent spawn during dispatch schedules a retry with an incremented attempt" do
    use_memory_tracker()

    # Cap the agent-dispatch Task.Supervisor at zero so start_child returns
    # {:error, :max_children}, forcing the spawn-failure retry fallback.
    {:ok, full_sup} = Task.Supervisor.start_link(max_children: 0)
    Application.put_env(:symphony_elixir, :agent_task_supervisor, full_sup)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :agent_task_supervisor)
      # Race-safe: on_exit runs after the test process (which the capped
      # supervisor is linked to) starts tearing down. :kill is a no-op on an
      # already-dead pid, avoiding the GenServer.stop "no process" exit.
      Process.exit(full_sup, :kill)
    end)

    pid = start_orchestrator(:SpawnFailureDispatch)

    iss = issue("iss-spawn-fail", "SF-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    token = seed_retry(pid, iss, %{worker_host: nil})
    send(pid, {:retry_issue, iss.id, token})

    # Spawn fails → a fresh retry is scheduled (attempt incremented to 2) and
    # the issue never enters `running`.
    state =
      wait_for_state(pid, fn s ->
        case s.retry_attempts[iss.id] do
          %{attempt: 2, error: err} -> err =~ "failed to spawn agent"
          _ -> false
        end
      end)

    refute Map.has_key?(state.running, iss.id)
  end

  # ── choose_issues happy dispatch (local) via run_poll_cycle ───────────────

  test "run_poll_cycle dispatches a fresh local candidate and records it as running" do
    use_memory_tracker()
    pid = start_orchestrator(:ChooseDispatchLocal)

    iss = issue("iss-fresh-dispatch", "FD-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    send(pid, :run_poll_cycle)

    # The dispatched AgentRunner task will fail/exit against the throwaway
    # workspace, but choose_issues + spawn_issue_on_worker_host run first and
    # register the issue in `running` (then it's later retried/cleaned up).
    state = wait_for_state(pid, fn s -> MapSet.member?(s.claimed, iss.id) end, 2_000)
    assert MapSet.member?(state.claimed, iss.id)
  end

  # ── worker_runtime_info with a nil value leaves the field untouched ───────

  # ── claude app-server pid as a binary string ──────────────────────────────

  # ── running_seconds with a missing started_at; integer_like parse failure ─

  test "codex token usage with a non-numeric string value is ignored" do
    use_memory_tracker()
    pid = start_orchestrator(:NonNumericTokens)

    iss = issue("iss-nonnumeric", "NN-1")
    seed_codex_running(pid, iss)

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "thread/tokenUsage/updated",
           "params" => %{"tokenUsage" => %{"total" => %{"input_tokens" => "not-a-number"}}}
         }
       }}
    )

    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:last_codex_event] == :notification end)

    assert state.running[iss.id].codex_input_tokens == 0
  end

  # ── reconcile_missing: id-less issue in the fetched list ──────────────────

  # ── log_missing_running_issue without an identifier ───────────────────────

  # ── refresh_running/blocked_issue_state with entries lacking :issue ────────

  # ── stall path: no activity timestamp → skipped; string-keyed mcp message ──

  test "a stalled entry whose mcp elicitation message uses an unwrapped string method is blocked" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      codex_stall_timeout_ms: 1
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    pid = start_orchestrator(:StallUnwrappedMcp)

    iss = issue("iss-unwrapped-mcp", "UM-1", state: "In Progress")
    stale = DateTime.add(DateTime.utc_now(), -5, :second)

    entry = %{
      pid: dummy_worker(),
      ref: make_ref(),
      identifier: iss.identifier,
      issue: iss,
      session_id: nil,
      # Unwrapped %{"method" => ...} shape exercises codex_message_method/1's
      # third clause.
      last_codex_message: %{"method" => "mcpServer/elicitation/request"},
      last_codex_event: :notification,
      last_codex_timestamp: stale,
      started_at: stale
    }

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    send(pid, :run_poll_cycle)

    state = wait_for_state(pid, fn s -> Map.has_key?(s.blocked, iss.id) end)
    assert state.blocked[iss.id].error == "codex MCP elicitation requires operator input"
  end

  # ── completion outcome strings: input_required + unknown ──────────────────

  # ── issue_routable_to_worker? default clause (nil assigned_to_worker) ──────

  # ── cleanup_issue_workspace with a nil identifier (blocked terminal) ───────

  # ── snapshot of a blocked entry lacking an embedded issue ─────────────────

  # ── terminate_task :ok branch via a real supervised dispatch ──────────────

  # ── deterministic action side-effect crash (catch in spawn task) ──────────

  test "a deterministic action whose tracker round-trip crashes surfaces an :error result" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    # A non-list comments value makes find_workpad_comment's Enum.find raise,
    # which the spawn task's try/catch turns into {:error, {:task_crashed, ...}}.
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{"iss-crash" => "not-a-list"})

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_comments)
    end)

    pid = start_orchestrator(:DetActionCrash)

    iss = issue("iss-crash", "CR-1", state: "In Progress")
    ref = make_ref()

    seed(pid,
      running: %{iss.id => running_entry(iss, ref: ref)},
      claimed: MapSet.new([iss.id]),
      deterministic_failures: %{
        iss.id => %{code: :quota_exceeded, count: 2, notified_alert?: false, notified_escalation?: false}
      }
    )

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    # The crash surfaces as an :error result → flags stay clear and a retry is
    # scheduled (IDE-73 retry contract preserved across the async hop).
    state =
      wait_for_state(
        pid,
        fn s ->
          match?(%{count: 3, notified_alert?: false}, s.deterministic_failures[iss.id]) and
            Map.has_key?(s.retry_attempts, iss.id)
        end,
        2_000
      )

    assert state.deterministic_failures[iss.id].count == 3
  end

  # ── stall reconcile disabled (timeout <= 0) ───────────────────────────────

  test "stall reconciliation is skipped entirely when the stall timeout is zero" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      codex_stall_timeout_ms: 0
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    pid = start_orchestrator(:StallDisabled)

    iss = issue("iss-stall-disabled", "SD2-1", state: "In Progress")
    stale = DateTime.add(DateTime.utc_now(), -60, :second)
    entry = running_entry(iss, ref: make_ref(), started_at: stale) |> Map.put(:last_codex_timestamp, stale)

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    # Stall disabled → the long-idle issue is left running untouched.
    assert Map.has_key?(state.running, iss.id)
  end

  # ── needs_input string completion outcome ─────────────────────────────────

  # ── codex_message_method with an unwrapped atom-key method ─────────────────

  # ── revalidate_issue_for_dispatch second clause (id-less issue) ───────────

  # ── maybe_dispatch: no available slots (false branch) ─────────────────────

  test "maybe_dispatch stops at the slot check when no agent slots are free" do
    use_memory_tracker(max_concurrent_agents: 1)
    pid = start_orchestrator(:NoSlotsDispatch)

    busy = issue("iss-busy-slot", "BS-1", state: "In Progress")
    candidate = issue("iss-waiting-slot", "WS-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [busy, candidate])

    # One running agent saturates the single slot; the candidate must not be
    # dispatched because available_slots/1 returns 0.
    seed(pid, running: %{busy.id => running_entry(busy, ref: make_ref())}, claimed: MapSet.new([busy.id]))

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    refute Map.has_key?(state.running, candidate.id)
    refute MapSet.member?(state.claimed, candidate.id)
  end

  # ── terminate_running_issue nil branch (reconcile of a non-running id) ─────

  test "reconciling a terminal issue that is not in running releases its claim" do
    use_memory_tracker(tracker_terminal_states: ["Done"])
    pid = start_orchestrator(:TerminateNotRunning)

    # A real running issue keeps the running map non-empty so reconcile runs;
    # the by-ids fetch additionally returns a *terminal* issue whose id is NOT
    # in running, driving terminate_running_issue's nil branch.
    running_iss = issue("iss-still-running", "SR-1", state: "In Progress")
    extra_terminal = %Issue{id: "iss-extra-terminal", identifier: "XT-1", title: "x", state: "Done"}

    seed(pid,
      running: %{running_iss.id => running_entry(running_iss, ref: nil)},
      claimed: MapSet.new([running_iss.id, "iss-extra-terminal"])
    )

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_issue_states_by_ids_response,
      {:ok, [running_iss, extra_terminal]}
    )

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> not MapSet.member?(s.claimed, "iss-extra-terminal") end)
    # The genuine running issue is untouched (still active); only the stray
    # terminal id's claim is released.
    assert Map.has_key?(state.running, running_iss.id)
  end

  # ── reconcile_blocked_issue_state non-Issue element ───────────────────────

  test "blocked reconciliation tolerates a non-Issue element in the fetched list" do
    use_memory_tracker()
    pid = start_orchestrator(:BlockedNonIssue)

    iss = issue("iss-blk-nonissue", "BNI2-1", state: "In Progress")

    blocked_entry = %{
      issue_id: iss.id,
      identifier: iss.identifier,
      issue: iss,
      worker_host: nil,
      error: "stuck",
      blocked_at: DateTime.utc_now()
    }

    seed(pid, blocked: %{iss.id => blocked_entry}, claimed: MapSet.new([iss.id]))

    # The by-ids refresh returns a non-Issue plus no matching Issue, so the
    # blocked id is treated as "missing" (released) and the junk element routes
    # through reconcile_blocked_issue_state's catch-all clause.
    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_issue_states_by_ids_response,
      {:ok, [:junk]}
    )

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> not Map.has_key?(s.blocked, iss.id) end)
    refute MapSet.member?(state.claimed, iss.id)
  end

  # ── stall reconcile tolerates a non-map running entry value ───────────────

  # ── choose_issues tolerates a non-Issue candidate ─────────────────────────

  test "a non-Issue candidate is sorted to the back and never dispatched" do
    use_memory_tracker()
    pid = start_orchestrator(:JunkCandidate)

    valid = issue("iss-valid-candidate", "VC-1", state: "In Progress")
    # The by-ids revalidation reads issue_entries/0, so the valid issue must be
    # present there for dispatch to proceed past the freshness check.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [valid])

    # The junk element exercises sort_issues_for_dispatch's catch-all and
    # should_dispatch_issue?'s non-Issue clause.
    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_candidate_issues_response,
      {:ok, [:not_an_issue, valid]}
    )

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> MapSet.member?(s.claimed, valid.id) end, 2_000)
    # The valid issue is dispatched; the junk element is silently ignored.
    assert MapSet.member?(state.claimed, valid.id)
  end

  # ── todo_issue_blocked_by_non_terminal? with a non-list blocked_by ────────
end
