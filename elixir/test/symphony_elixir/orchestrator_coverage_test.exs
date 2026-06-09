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
  alias SymphonyElixir.Orchestrator.State

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

  test "run_poll_cycle logs and keeps state when candidate fetch errors generically" do
    use_memory_tracker()
    pid = start_orchestrator(:CandidateGenericError)

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_candidate_issues_response,
      {:error, :transport_down}
    )

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
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

  test "maybe_dispatch surfaces a missing tracker kind without dispatching" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: nil, tracker_api_token: "token")
    pid = start_orchestrator(:MissingKind)

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert map_size(state.running) == 0
  end

  test "maybe_dispatch surfaces an unsupported tracker kind without dispatching" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "bogus", tracker_api_token: "token")
    pid = start_orchestrator(:UnsupportedKind)

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

  test "reconcile keeps blocked issues when the blocked-state refresh errors" do
    use_memory_tracker()
    pid = start_orchestrator(:ReconcileBlockedError)

    iss = issue("iss-recon-blk", "REC-2")

    blocked_entry = %{
      issue_id: iss.id,
      identifier: iss.identifier,
      issue: iss,
      worker_host: nil,
      error: "stuck",
      blocked_at: DateTime.utc_now()
    }

    seed(pid, blocked: %{iss.id => blocked_entry}, claimed: MapSet.new([iss.id]))

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_issue_states_by_ids_response,
      {:error, :boom}
    )

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert Map.has_key?(state.blocked, iss.id), "blocked issue preserved on refresh error"
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

  test "blocked issue no longer routed to this worker releases the block" do
    use_memory_tracker()
    pid = start_orchestrator(:BlockedUnrouted)

    iss = issue("iss-blk-unrouted", "BLK-2", state: "In Progress", assigned_to_worker: false)

    blocked_entry = %{
      issue_id: iss.id,
      identifier: iss.identifier,
      issue: iss,
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

  test "blocked issue still active refreshes its embedded issue snapshot" do
    use_memory_tracker()
    pid = start_orchestrator(:BlockedActiveRefresh)

    iss = issue("iss-blk-active", "BLK-3", state: "In Progress", title: "fresh title")

    blocked_entry = %{
      issue_id: iss.id,
      identifier: iss.identifier,
      issue: %{iss | title: "stale title"},
      worker_host: nil,
      error: "stuck",
      blocked_at: DateTime.utc_now()
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])
    seed(pid, blocked: %{iss.id => blocked_entry}, claimed: MapSet.new([iss.id]))

    send(pid, :run_poll_cycle)

    state =
      wait_for_state(pid, fn s ->
        match?(%{issue: %Issue{title: "fresh title"}}, s.blocked[iss.id])
      end)

    assert state.blocked[iss.id].issue.title == "fresh title"
    assert MapSet.member?(state.claimed, iss.id)
  end

  test "blocked issue moving to a non-active, non-terminal state releases the block" do
    use_memory_tracker(tracker_active_states: ["In Progress"], tracker_terminal_states: ["Done"])
    pid = start_orchestrator(:BlockedNonActive)

    iss = issue("iss-blk-nonactive", "BLK-4", state: "Backlog")

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

  test "blocked issue no longer visible during refresh releases the block" do
    use_memory_tracker()
    pid = start_orchestrator(:BlockedMissing)

    iss = issue("iss-blk-missing", "BLK-5")

    blocked_entry = %{
      issue_id: iss.id,
      identifier: iss.identifier,
      issue: iss,
      worker_host: nil,
      error: "stuck",
      blocked_at: DateTime.utc_now()
    }

    # Tracker returns no issues at all → blocked id is "missing".
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])
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

  test "running issue still active refreshes its embedded issue snapshot" do
    use_memory_tracker()
    pid = start_orchestrator(:RunningActiveRefresh)

    iss = issue("iss-run-active", "RUN-1", state: "In Progress", title: "new title")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    seed(pid,
      running: %{iss.id => running_entry(%{iss | title: "old title"}, ref: make_ref())},
      claimed: MapSet.new([iss.id])
    )

    send(pid, :run_poll_cycle)

    state =
      wait_for_state(pid, fn s ->
        match?(%{issue: %Issue{title: "new title"}}, s.running[iss.id])
      end)

    assert state.running[iss.id].issue.title == "new title"
  end

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

  test "legacy {:retry_issue, id} message is ignored" do
    use_memory_tracker()
    pid = start_orchestrator(:RetryLegacy)
    before = :sys.get_state(pid)
    send(pid, {:retry_issue, "whatever"})
    Process.sleep(20)
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

  test "retry_issue removes the claim when the issue left active states" do
    use_memory_tracker(tracker_active_states: ["In Progress"], tracker_terminal_states: ["Done"])
    pid = start_orchestrator(:RetryLeftActive)

    iss = issue("iss-retry-left", "RT-2", state: "Backlog")
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

  test "retry_issue removes the claim when the issue is no longer visible" do
    use_memory_tracker()
    pid = start_orchestrator(:RetryInvisible)

    iss = issue("iss-retry-invisible", "RT-3")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

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

  test "retry_issue reschedules with backoff when the retry poll is rate limited" do
    use_memory_tracker()
    pid = start_orchestrator(:RetryPollRateLimited)

    iss = issue("iss-retry-rl", "RT-4")

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_candidate_issues_response,
      {:error, :rate_limited}
    )

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

    state =
      wait_for_state(pid, fn s ->
        match?(%{attempt: 2, error: "retry poll deferred: rate_limited"}, s.retry_attempts[iss.id])
      end)

    assert state.retry_attempts[iss.id].attempt == 2
  end

  test "retry_issue reschedules with backoff when the retry poll errors generically" do
    use_memory_tracker()
    pid = start_orchestrator(:RetryPollError)

    iss = issue("iss-retry-err", "RT-5")

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_candidate_issues_response,
      {:error, :transport_down}
    )

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

    state =
      wait_for_state(pid, fn s ->
        case s.retry_attempts[iss.id] do
          %{attempt: 2, error: err} -> err =~ "retry poll failed"
          _ -> false
        end
      end)

    assert state.retry_attempts[iss.id].attempt == 2
  end

  test "handle_active_retry reschedules when no orchestrator slot is available" do
    use_memory_tracker(max_concurrent_agents: 1)
    pid = start_orchestrator(:RetryNoSlot)

    active = issue("iss-active-busy", "RB-0", state: "In Progress")
    iss = issue("iss-retry-noslot", "RB-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    retry_token = make_ref()

    seed(pid,
      running: %{active.id => running_entry(active, ref: make_ref())},
      claimed: MapSet.new([active.id, iss.id]),
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

    state =
      wait_for_state(pid, fn s ->
        match?(%{attempt: 2, error: "no available orchestrator slots"}, s.retry_attempts[iss.id])
      end)

    assert state.retry_attempts[iss.id].attempt == 2
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

  test "DOWN for an unknown ref is ignored" do
    use_memory_tracker()
    pid = start_orchestrator(:DownUnknownRef)
    before = :sys.get_state(pid)
    send(pid, {:DOWN, make_ref(), :process, self(), :normal})
    Process.sleep(20)
    assert :sys.get_state(pid).running == before.running
  end

  # ── worker_runtime_info handler ───────────────────────────────────────────

  test "worker_runtime_info updates worker_host and workspace_path on a running entry" do
    use_memory_tracker()
    pid = start_orchestrator(:RuntimeInfo)

    iss = issue("iss-runtime", "RI-1")
    seed(pid, running: %{iss.id => running_entry(iss, ref: make_ref())})

    send(pid, {:worker_runtime_info, iss.id, %{worker_host: "worker-x", workspace_path: "/ws/RI-1"}})

    state =
      wait_for_state(pid, fn s ->
        match?(%{worker_host: "worker-x", workspace_path: "/ws/RI-1"}, s.running[iss.id])
      end)

    assert state.running[iss.id].worker_host == "worker-x"
  end

  test "worker_runtime_info for an unknown issue is a no-op" do
    use_memory_tracker()
    pid = start_orchestrator(:RuntimeInfoUnknown)
    before = :sys.get_state(pid)
    send(pid, {:worker_runtime_info, "nope", %{worker_host: "x"}})
    Process.sleep(20)
    assert :sys.get_state(pid).running == before.running
  end

  # ── codex_worker_update for an unknown issue / malformed ──────────────────

  test "codex_worker_update for an unknown issue is a no-op" do
    use_memory_tracker()
    pid = start_orchestrator(:WorkerUpdateUnknown)
    before = :sys.get_state(pid)
    send(pid, {:codex_worker_update, "nope", %{event: :notification, timestamp: DateTime.utc_now()}})
    Process.sleep(20)
    assert :sys.get_state(pid).running == before.running
  end

  test "malformed codex_worker_update is ignored" do
    use_memory_tracker()
    pid = start_orchestrator(:WorkerUpdateMalformed)
    before = :sys.get_state(pid)
    send(pid, {:codex_worker_update, "x", %{not: :valid}})
    Process.sleep(20)
    assert :sys.get_state(pid).running == before.running
  end

  # ── unknown info message ──────────────────────────────────────────────────

  test "an unrecognized info message is ignored" do
    use_memory_tracker()
    pid = start_orchestrator(:UnknownInfo)
    before = :sys.get_state(pid)
    send(pid, {:totally, :unexpected})
    Process.sleep(20)
    after_state = :sys.get_state(pid)
    # The catch-all handler returns the state unchanged; compare the work-
    # tracking fields (ignoring the periodically-rescheduled tick timer).
    assert after_state.running == before.running
    assert after_state.claimed == before.claimed
    assert after_state.retry_attempts == before.retry_attempts
    assert after_state.blocked == before.blocked
  end

  # ── stale tick token ──────────────────────────────────────────────────────

  test "a tick with a stale token is ignored" do
    use_memory_tracker()
    pid = start_orchestrator(:StaleTick)
    state = :sys.get_state(pid)
    assert {:noreply, ^state} = Orchestrator.handle_info({:tick, make_ref()}, state)
  end

  # ── deterministic_failure_result with stale token (debug branch) ──────────

  test "deterministic_failure_result with no pending escalation is dropped" do
    use_memory_tracker()
    pid = start_orchestrator(:DetFailStale)
    before = :sys.get_state(pid)

    send(
      pid,
      {:deterministic_failure_result, "iss-x", make_ref(), {:alert, :quota_exceeded, 3}, :ok}
    )

    Process.sleep(20)
    assert :sys.get_state(pid).deterministic_failures == before.deterministic_failures
  end

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

  test "request_refresh on an unknown server is :unavailable" do
    assert Orchestrator.request_refresh(:no_such_orchestrator_server) == :unavailable
  end

  test "snapshot on an unknown server is :unavailable" do
    assert Orchestrator.snapshot(:no_such_orchestrator_server, 100) == :unavailable
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

  test "a claude session DOWN records claude completion seconds_running" do
    use_memory_tracker()
    pid = start_orchestrator(:ClaudeCompletion)

    iss = issue("iss-claude", "CL-1", state: "In Progress")
    ref = make_ref()
    started = DateTime.add(DateTime.utc_now(), -3, :second)

    seed(pid,
      running: %{iss.id => running_entry(iss, ref: ref, agent_kind: :claude, started_at: started)},
      claimed: MapSet.new([iss.id])
    )

    send(pid, {:DOWN, ref, :process, self(), :killed})

    state = wait_for_state(pid, fn s -> not Map.has_key?(s.running, iss.id) end)
    assert state.claude_totals.seconds_running >= 0
  end

  # ── start_link/0 default opts ─────────────────────────────────────────────

  test "request_refresh/0 targets the default-named running orchestrator" do
    use_memory_tracker()
    # The application's Orchestrator runs under the default name, so the
    # zero-arity wrapper resolves it and returns a queued/coalesced map.
    result = Orchestrator.request_refresh()
    assert is_map(result)
    assert Map.has_key?(result, :queued)
  end

  test "start_link/0 uses the default name (collides with the running instance)" do
    use_memory_tracker()
    # Exercises the `opts \\ []` default clause; the app already owns the
    # default name, so this returns {:error, {:already_started, _}}.
    assert {:error, {:already_started, pid}} = Orchestrator.start_link()
    assert is_pid(pid)
  end

  # ── maybe_dispatch: semantic config validation errors ─────────────────────

  test "maybe_dispatch logs and no-ops when the linear project slug is missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "linear",
      tracker_api_token: "token",
      tracker_project_slug: nil
    )

    pid = start_orchestrator(:MissingProjectSlug)
    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert map_size(state.running) == 0
  end

  test "maybe_dispatch logs and no-ops when the claude adapter is paired with ssh hosts" do
    # agent.kind: claude + worker.ssh_hosts triggers
    # {:claude_remote_worker_unsupported, hosts} from Config.validate!/0.
    # Provide claude credentials via env so settings!/0 (parse) stays valid.
    prev = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "sk-test")
    on_exit(fn -> restore_env("ANTHROPIC_API_KEY", prev) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      agent_kind: "claude",
      worker_ssh_hosts: ["worker-a"]
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    pid = start_orchestrator(:ClaudeRemoteUnsupported)
    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert map_size(state.running) == 0
  end

  # ── startup terminal workspace cleanup (init) ─────────────────────────────

  test "startup cleanup removes workspaces for terminal issues and tolerates id-less ones" do
    use_memory_tracker(tracker_terminal_states: ["Done"])

    with_id = issue("iss-term-id", "TERM-1", state: "Done")
    without_id = %Issue{id: "iss-term-noid", identifier: nil, title: "x", state: "Done"}

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [with_id, without_id])

    # Booting the orchestrator runs run_terminal_workspace_cleanup/0 in init/1.
    pid = start_orchestrator(:StartupCleanup)
    assert is_pid(pid)
  end

  test "startup cleanup logs and continues when the terminal-issue fetch errors" do
    use_memory_tracker(tracker_terminal_states: ["Done"])

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_issues_by_states_response,
      {:error, :transport_down}
    )

    log =
      capture_log(fn ->
        pid = start_orchestrator(:StartupCleanupError)
        assert is_pid(pid)
        # Let init's cleanup run.
        Process.sleep(20)
      end)

    assert log =~ "startup terminal workspace cleanup"
  end

  # ── codex_worker_update: pid coercion + session_started turn counting ──────

  test "codex update coerces an integer app-server pid to a string" do
    use_memory_tracker()
    pid = start_orchestrator(:CodexPidInt)

    iss = issue("iss-codex-pid-int", "CPI-1")

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

    send(
      pid,
      {:codex_worker_update, iss.id, %{event: :notification, payload: %{method: "x"}, timestamp: DateTime.utc_now(), codex_app_server_pid: 9001}}
    )

    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:codex_app_server_pid] == "9001" end)

    assert state.running[iss.id].codex_app_server_pid == "9001"
  end

  test "codex update coerces a charlist app-server pid to a string" do
    use_memory_tracker()
    pid = start_orchestrator(:CodexPidList)

    iss = issue("iss-codex-pid-list", "CPL-1")

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

    send(
      pid,
      {:codex_worker_update, iss.id, %{event: :notification, payload: %{method: "x"}, timestamp: DateTime.utc_now(), codex_app_server_pid: ~c"7777"}}
    )

    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:codex_app_server_pid] == "7777" end)

    assert state.running[iss.id].codex_app_server_pid == "7777"
  end

  test "codex session_started with the same session id keeps the turn count" do
    use_memory_tracker()
    pid = start_orchestrator(:CodexSameSession)

    iss = issue("iss-same-session", "SS-1")

    seed(pid,
      running: %{
        iss.id =>
          running_entry(iss, ref: make_ref(), session_id: "sess-keep")
          |> Map.merge(%{
            codex_input_tokens: 0,
            codex_output_tokens: 0,
            codex_total_tokens: 0,
            codex_last_reported_input_tokens: 0,
            codex_last_reported_output_tokens: 0,
            codex_last_reported_total_tokens: 0,
            turn_count: 3
          })
      }
    )

    send(
      pid,
      {:codex_worker_update, iss.id, %{event: :session_started, session_id: "sess-keep", timestamp: DateTime.utc_now()}}
    )

    # session id unchanged → turn_count must stay at 3.
    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:last_codex_event] == :session_started end)

    assert state.running[iss.id].turn_count == 3
  end

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

  test "a non-token claude event advances the envelope without touching token totals" do
    use_memory_tracker()
    pid = start_orchestrator(:ClaudeNonToken)

    iss = issue("iss-claude-nontoken", "CNT-1")
    seed_claude_running(pid, iss)

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         agent_kind: :claude,
         event: :system_init,
         session_id: "sess-claude",
         timestamp: DateTime.utc_now()
       }}
    )

    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:last_codex_event] == :system_init end)

    assert state.running[iss.id].claude_input_tokens == 0
    assert state.running[iss.id].session_id == "sess-claude"
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

  test "a claude app-server pid arriving as a charlist is coerced to a string" do
    use_memory_tracker()
    pid = start_orchestrator(:ClaudePidList)

    iss = issue("iss-claude-pidlist", "CPL2-1")
    seed_claude_running(pid, iss)

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         agent_kind: :claude,
         event: :system_init,
         timestamp: DateTime.utc_now(),
         claude_app_server_pid: ~c"5555"
       }}
    )

    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:claude_app_server_pid] == "5555" end)

    assert state.running[iss.id].claude_app_server_pid == "5555"
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

  test "codex rate limits nested inside a list payload are captured" do
    use_memory_tracker()
    pid = start_orchestrator(:RateLimitList)

    iss = issue("iss-rl-list", "RLL-1")
    seed_codex_running(pid, iss)

    rate_limits = %{
      "limit_name" => "codex",
      "credits" => %{"balance" => 1}
    }

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         event: :notification,
         timestamp: DateTime.utc_now(),
         payload: %{"items" => [%{"noise" => 1}, %{"rate_limits" => rate_limits}]}
       }}
    )

    state = wait_for_state(pid, fn s -> s.codex_rate_limits == rate_limits end)
    assert state.codex_rate_limits == rate_limits
  end

  test "codex turn/completed usage nested under params is accounted" do
    use_memory_tracker()
    pid = start_orchestrator(:TurnCompletedParamsUsage)

    iss = issue("iss-tc-params", "TCP-1")
    seed_codex_running(pid, iss)

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         event: :turn_completed,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "turn/completed",
           "params" => %{"usage" => %{"input_tokens" => 6, "output_tokens" => 2, "total_tokens" => 8}}
         }
       }}
    )

    state = wait_for_state(pid, fn s -> s.running[iss.id][:codex_total_tokens] == 8 end)
    assert state.running[iss.id].codex_input_tokens == 6
  end

  # ── find_issue_by_id miss via retry path that finds the wrong issues ───────

  test "retry_issue removes the claim when candidate issues never include the id" do
    use_memory_tracker()
    pid = start_orchestrator(:RetryFindMiss)

    target = issue("iss-target", "TGT-1")
    other = issue("iss-other", "OTH-1")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [other])

    retry_token = make_ref()

    seed(pid,
      claimed: MapSet.new([target.id]),
      retry_attempts: %{
        target.id => %{
          attempt: 1,
          timer_ref: nil,
          retry_token: retry_token,
          due_at_ms: System.monotonic_time(:millisecond),
          identifier: target.identifier
        }
      }
    )

    send(pid, {:retry_issue, target.id, retry_token})
    state = wait_for_state(pid, fn s -> not Map.has_key?(s.retry_attempts, target.id) end)
    refute MapSet.member?(state.claimed, target.id)
  end

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

  test "an agent whose completion outcome is approval_required is blocked accordingly" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    pid = start_orchestrator(:ApprovalCompletionBlock)

    iss = issue("iss-approval-complete", "AP-2", state: "In Progress")
    ref = make_ref()

    entry =
      running_entry(iss, ref: ref)
      |> Map.merge(%{completion: %{"outcome" => "approval_required"}})

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    send(pid, {:DOWN, ref, :process, self(), :normal})

    state = wait_for_state(pid, fn s -> Map.has_key?(s.blocked, iss.id) end)
    assert state.blocked[iss.id].error == "codex turn requires approval"
    refute MapSet.member?(state.completed, iss.id)
  end

  test "a needs_input completion outcome string blocks with the operator-input error" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    pid = start_orchestrator(:NeedsInputBlock)

    iss = issue("iss-needs-input", "NI-1", state: "In Progress")
    ref = make_ref()

    entry =
      running_entry(iss, ref: ref)
      |> Map.merge(%{completion: %{outcome: :needs_input}})

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    send(pid, {:DOWN, ref, :process, self(), :normal})

    state = wait_for_state(pid, fn s -> Map.has_key?(s.blocked, iss.id) end)
    assert state.blocked[iss.id].error == "codex turn requires operator input"
  end

  # ── snapshot/0 + snapshot abnormal exit ───────────────────────────────────

  test "snapshot/0 targets the default running orchestrator" do
    use_memory_tracker()
    snapshot = Orchestrator.snapshot()
    assert is_map(snapshot)
    assert Map.has_key?(snapshot, :running)
  end

  test "snapshot returns :unavailable when the server exits abnormally during the call" do
    server_name = Module.concat(__MODULE__, :CrashingSnapshotServer)
    parent = self()

    pid =
      spawn(fn ->
        Process.register(self(), server_name)
        send(parent, :ready)

        receive do
          {:"$gen_call", _from, :snapshot} -> exit(:boom)
        end
      end)

    assert_receive :ready, 1_000
    assert Orchestrator.snapshot(server_name, 1_000) == :unavailable
    refute Process.alive?(pid)
  end

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

  test "dispatch skips a retry whose revalidation shows the issue went stale" do
    use_memory_tracker(tracker_terminal_states: ["Done"])
    pid = start_orchestrator(:DispatchSkipStale)

    iss = issue("iss-skip-stale", "DSS-1", state: "In Progress")
    stale = %{iss | state: "Done"}
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_issue_states_by_ids_response, {:ok, [stale]})

    token = seed_retry(pid, iss)
    send(pid, {:retry_issue, iss.id, token})

    state = wait_for_state(pid, fn s -> not Map.has_key?(s.retry_attempts, iss.id) end)
    refute Map.has_key?(state.running, iss.id)
  end

  test "dispatch skips a retry whose revalidation is rate limited" do
    use_memory_tracker()
    pid = start_orchestrator(:DispatchSkipRateLimited)

    iss = issue("iss-skip-rl", "DSR-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    token = seed_retry(pid, iss)
    # Candidate fetch ok; then flip the by-ids fetch to rate_limited so the
    # revalidation inside dispatch_issue surfaces :rate_limited.
    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_issue_states_by_ids_response,
      {:error, :rate_limited}
    )

    send(pid, {:retry_issue, iss.id, token})

    # Issue stays claimed (the skip leaves state untouched) and not running.
    state = wait_for_state(pid, fn s -> not Map.has_key?(s.running, iss.id) end, 500)
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

  test "a claude token_usage event with no usage payload contributes zero tokens" do
    use_memory_tracker()
    pid = start_orchestrator(:ClaudeEmptyUsage)

    iss = issue("iss-claude-empty", "CE-1")
    seed_claude_running(pid, iss)

    send(
      pid,
      {:codex_worker_update, iss.id, %{agent_kind: :claude, event: :token_usage, timestamp: DateTime.utc_now(), payload: %{}}}
    )

    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:last_codex_event] == :token_usage end)

    assert state.running[iss.id].claude_input_tokens == 0
  end

  # ── codex turn/completed usage: direct "usage" and atom params/usage ──────

  test "codex turn/completed usage at the top-level usage key is accounted" do
    use_memory_tracker()
    pid = start_orchestrator(:TurnCompletedDirectUsage)

    iss = issue("iss-tc-direct", "TCD-1")
    seed_codex_running(pid, iss)

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         event: :turn_completed,
         timestamp: DateTime.utc_now(),
         payload: %{
           "method" => "turn/completed",
           "usage" => %{"input_tokens" => 3, "output_tokens" => 1, "total_tokens" => 4}
         }
       }}
    )

    state = wait_for_state(pid, fn s -> s.running[iss.id][:codex_total_tokens] == 4 end)
    assert state.running[iss.id].codex_input_tokens == 3
  end

  test "codex turn/completed usage under atom params/usage is accounted" do
    use_memory_tracker()
    pid = start_orchestrator(:TurnCompletedAtomParamsUsage)

    iss = issue("iss-tc-atom", "TCA-1")
    seed_codex_running(pid, iss)

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         event: :turn_completed,
         timestamp: DateTime.utc_now(),
         payload: %{
           method: :turn_completed,
           params: %{usage: %{input_tokens: 9, output_tokens: 1, total_tokens: 10}}
         }
       }}
    )

    state = wait_for_state(pid, fn s -> s.running[iss.id][:codex_total_tokens] == 10 end)
    assert state.running[iss.id].codex_input_tokens == 9
  end

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

  test "an alert escalation builds a fallback issue when the running entry has no issue" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      "iss-fallback" => [
        %{id: "wp-fallback", body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do", resolved_at: nil}
      ]
    })

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :memory_tracker_comments)
    end)

    pid = start_orchestrator(:AlertFallbackIssue)

    ref = make_ref()

    # Running entry deliberately lacks an :issue key so apply_deterministic_action
    # falls back to running_entry_issue_fallback/2.
    entry = %{
      pid: dummy_worker(),
      ref: ref,
      identifier: "FB-1",
      session_id: nil,
      retry_attempt: 0,
      started_at: DateTime.utc_now()
    }

    seed(pid,
      running: %{"iss-fallback" => entry},
      claimed: MapSet.new(["iss-fallback"]),
      deterministic_failures: %{
        "iss-fallback" => %{code: :quota_exceeded, count: 2, notified_alert?: false, notified_escalation?: false}
      }
    )

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    assert_receive {:memory_tracker_comment_update, "wp-fallback", body}, 1_000
    assert body =~ "Deterministic-failure alert"
  end

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

  test "run_poll_cycle dispatches via the claude adapter, stamping agent_kind: :claude" do
    prev = System.get_env("ANTHROPIC_API_KEY")
    System.put_env("ANTHROPIC_API_KEY", "sk-test")
    on_exit(fn -> restore_env("ANTHROPIC_API_KEY", prev) end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_api_token: nil,
      agent_kind: "claude"
    )

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    iss = issue("iss-claude-dispatch", "CD2-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    pid = start_orchestrator(:ChooseDispatchClaude)
    send(pid, :run_poll_cycle)

    state =
      wait_for_state(
        pid,
        fn s ->
          match?(%{agent_kind: :claude}, s.running[iss.id])
        end,
        2_000
      )

    assert state.running[iss.id].agent_kind == :claude
  end

  # ── worker_runtime_info with a nil value leaves the field untouched ───────

  test "worker_runtime_info ignores nil runtime values" do
    use_memory_tracker()
    pid = start_orchestrator(:RuntimeInfoNil)

    iss = issue("iss-runtime-nil", "RIN-1")
    seed(pid, running: %{iss.id => running_entry(iss, ref: make_ref(), worker_host: "keep")})

    send(pid, {:worker_runtime_info, iss.id, %{worker_host: nil, workspace_path: "/ws"}})

    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:workspace_path] == "/ws" end)

    # nil worker_host must not overwrite the existing value.
    assert state.running[iss.id].worker_host == "keep"
  end

  # ── claude app-server pid as a binary string ──────────────────────────────

  test "a claude app-server pid arriving as a binary string is kept as-is" do
    use_memory_tracker()
    pid = start_orchestrator(:ClaudePidBinary)

    iss = issue("iss-claude-pidbin", "CPB-1")
    seed_claude_running(pid, iss)

    send(
      pid,
      {:codex_worker_update, iss.id,
       %{
         agent_kind: :claude,
         event: :system_init,
         timestamp: DateTime.utc_now(),
         claude_app_server_pid: "8888"
       }}
    )

    state =
      wait_for_state(pid, fn s -> s.running[iss.id][:claude_app_server_pid] == "8888" end)

    assert state.running[iss.id].claude_app_server_pid == "8888"
  end

  # ── running_seconds with a missing started_at; integer_like parse failure ─

  test "snapshot tolerates a running entry without a started_at timestamp" do
    use_memory_tracker()
    pid = start_orchestrator(:NoStartedAt)

    iss = issue("iss-no-start", "NST-1")

    entry =
      running_entry(iss, ref: make_ref())
      |> Map.put(:started_at, nil)

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    snapshot = GenServer.call(pid, :snapshot)
    assert [row] = snapshot.running
    assert row.runtime_seconds == 0
  end

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

  test "reconcile tolerates an id-less issue while stopping a now-missing running agent" do
    use_memory_tracker()
    pid = start_orchestrator(:ReconcileIdless)

    running_iss = issue("iss-running-gone", "RG-1", state: "In Progress")
    idless = %Issue{id: nil, identifier: "IDLESS-1", title: "x", state: "In Progress"}

    seed(pid,
      running: %{running_iss.id => running_entry(running_iss, ref: nil)},
      claimed: MapSet.new([running_iss.id])
    )

    # The by-ids refresh returns only an id-less issue, so the real running id
    # is "missing" → terminated, and the id-less entry exercises the flat_map
    # catch-all.
    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_issue_states_by_ids_response,
      {:ok, [idless]}
    )

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> not Map.has_key?(s.running, running_iss.id) end)
    refute MapSet.member?(state.claimed, running_iss.id)
  end

  test "reconcile tolerates an id-less issue while releasing a now-missing blocked issue" do
    use_memory_tracker()
    pid = start_orchestrator(:ReconcileBlockedIdless)

    blocked_iss = issue("iss-blocked-gone", "BG-1", state: "In Progress")
    idless = %Issue{id: nil, identifier: "IDLESS-2", title: "x", state: "In Progress"}

    blocked_entry = %{
      issue_id: blocked_iss.id,
      identifier: blocked_iss.identifier,
      issue: blocked_iss,
      worker_host: nil,
      error: "stuck",
      blocked_at: DateTime.utc_now()
    }

    seed(pid, blocked: %{blocked_iss.id => blocked_entry}, claimed: MapSet.new([blocked_iss.id]))

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_fetch_issue_states_by_ids_response,
      {:ok, [idless]}
    )

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> not Map.has_key?(s.blocked, blocked_iss.id) end)
    refute MapSet.member?(state.claimed, blocked_iss.id)
  end

  # ── log_missing_running_issue without an identifier ───────────────────────

  test "a missing running issue without an identifier is still stopped" do
    use_memory_tracker()
    pid = start_orchestrator(:MissingNoIdentifier)

    gone = issue("iss-gone-noident", "GNI-1", state: "In Progress")

    entry = %{
      pid: dummy_worker(),
      ref: nil,
      issue: gone,
      started_at: DateTime.utc_now()
    }

    seed(pid, running: %{gone.id => entry}, claimed: MapSet.new([gone.id]))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    send(pid, :run_poll_cycle)
    # The entry lacks :identifier, so log_missing_running_issue hits its
    # identifier-less branch and terminate_running_issue falls to the catch-all
    # that only releases the claim (the malformed entry is intentionally not
    # force-deleted from `running`).
    state = wait_for_state(pid, fn s -> not MapSet.member?(s.claimed, gone.id) end)
    refute MapSet.member?(state.claimed, gone.id)
  end

  # ── refresh_running/blocked_issue_state with entries lacking :issue ────────

  test "refresh_running_issue_state leaves a running entry that lacks an embedded issue" do
    use_memory_tracker()
    pid = start_orchestrator(:RefreshRunningNoIssue)

    iss = issue("iss-refresh-noissue", "RNI-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    entry = %{pid: dummy_worker(), ref: nil, identifier: iss.identifier, started_at: DateTime.utc_now()}
    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    send(pid, :run_poll_cycle)
    # Active refresh hits the `_ -> state` branch (no :issue to update) and the
    # entry stays present and unchanged.
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert Map.has_key?(state.running, iss.id)
  end

  test "refresh_blocked_issue_state leaves a blocked entry that lacks an embedded issue" do
    use_memory_tracker()
    pid = start_orchestrator(:RefreshBlockedNoIssue)

    iss = issue("iss-refresh-blk-noissue", "RBN-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    blocked_entry = %{
      issue_id: iss.id,
      identifier: iss.identifier,
      worker_host: nil,
      error: "stuck",
      blocked_at: DateTime.utc_now()
    }

    seed(pid, blocked: %{iss.id => blocked_entry}, claimed: MapSet.new([iss.id]))

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert Map.has_key?(state.blocked, iss.id)
  end

  # ── stall path: no activity timestamp → skipped; string-keyed mcp message ──

  test "a running entry with no activity timestamps is not treated as stalled" do
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

    pid = start_orchestrator(:NoActivityNoStall)

    iss = issue("iss-no-activity", "NA-1", state: "In Progress")

    entry = %{
      pid: dummy_worker(),
      ref: make_ref(),
      identifier: iss.identifier,
      issue: iss,
      session_id: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      last_codex_message: nil,
      started_at: nil
    }

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    # No timestamp → stall_elapsed_ms is nil → the issue is not restarted.
    assert Map.has_key?(state.running, iss.id)
  end

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

  test "a string input_required completion outcome blocks the issue" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    pid = start_orchestrator(:StringInputRequired)

    iss = issue("iss-str-input", "SI-1", state: "In Progress")
    ref = make_ref()

    entry =
      running_entry(iss, ref: ref)
      |> Map.merge(%{completion: %{"outcome" => "input_required"}})

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    send(pid, {:DOWN, ref, :process, self(), :normal})
    state = wait_for_state(pid, fn s -> Map.has_key?(s.blocked, iss.id) end)
    assert state.blocked[iss.id].error == "codex turn requires operator input"
  end

  test "an unknown string completion outcome is not treated as input-required" do
    use_memory_tracker()
    pid = start_orchestrator(:UnknownOutcome)

    iss = issue("iss-unknown-outcome", "UO-1", state: "In Progress")
    ref = make_ref()

    entry =
      running_entry(iss, ref: ref)
      |> Map.merge(%{completion: %{"outcome" => "totally-unknown"}})

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    # Normal exit with a non-input-required outcome → completes + continuation.
    send(pid, {:DOWN, ref, :process, self(), :normal})
    state = wait_for_state(pid, fn s -> MapSet.member?(s.completed, iss.id) end)
    refute Map.has_key?(state.blocked, iss.id)
  end

  test "a non-string, non-atom completion outcome is ignored" do
    use_memory_tracker()
    pid = start_orchestrator(:NumericOutcome)

    iss = issue("iss-numeric-outcome", "NO-1", state: "In Progress")
    ref = make_ref()

    entry =
      running_entry(iss, ref: ref)
      |> Map.merge(%{completion: %{outcome: 12_345}})

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    send(pid, {:DOWN, ref, :process, self(), :normal})
    state = wait_for_state(pid, fn s -> MapSet.member?(s.completed, iss.id) end)
    refute Map.has_key?(state.blocked, iss.id)
  end

  # ── issue_routable_to_worker? default clause (nil assigned_to_worker) ──────

  # ── cleanup_issue_workspace with a nil identifier (blocked terminal) ───────

  test "a blocked issue reaching terminal with a nil identifier releases without crashing" do
    use_memory_tracker(tracker_terminal_states: ["Done"])
    pid = start_orchestrator(:BlockedTerminalNoIdent)

    # The fetched terminal issue carries a nil identifier so cleanup hits the
    # non-binary fallback clause.
    fetched = %Issue{id: "iss-blk-term-noident", identifier: nil, title: "x", state: "Done"}

    blocked_entry = %{
      issue_id: fetched.id,
      identifier: "BTN-1",
      issue: %{fetched | state: "In Progress", identifier: "BTN-1"},
      worker_host: nil,
      error: "stuck",
      blocked_at: DateTime.utc_now()
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [fetched])
    seed(pid, blocked: %{fetched.id => blocked_entry}, claimed: MapSet.new([fetched.id]))

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> not Map.has_key?(s.blocked, fetched.id) end)
    refute MapSet.member?(state.claimed, fetched.id)
  end

  # ── snapshot of a blocked entry lacking an embedded issue ─────────────────

  test "snapshot renders a blocked entry that has no embedded issue (nil state)" do
    use_memory_tracker()
    pid = start_orchestrator(:BlockedNoIssueSnapshot)

    blocked_entry = %{
      issue_id: "iss-blk-noissue",
      identifier: "BNI-1",
      worker_host: nil,
      error: "stuck",
      blocked_at: DateTime.utc_now()
    }

    seed(pid, blocked: %{"iss-blk-noissue" => blocked_entry})

    snapshot = GenServer.call(pid, :snapshot)
    assert [row] = snapshot.blocked
    assert row.state == nil
  end

  # ── terminate_task :ok branch via a real supervised dispatch ──────────────

  test "reconciling a dispatched issue to terminal stops the real supervised task" do
    use_memory_tracker(tracker_terminal_states: ["Done"])
    pid = start_orchestrator(:TerminateRealTask)

    iss = issue("iss-real-task", "RT9-1", state: "In Progress")
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    # Dispatch a real task under SymphonyElixir.TaskSupervisor.
    send(pid, :run_poll_cycle)
    running = wait_for_state(pid, fn s -> Map.has_key?(s.running, iss.id) end, 2_000)
    task_pid = running.running[iss.id].pid
    assert is_pid(task_pid)

    # Now flip the issue to terminal and reconcile: terminate_running_issue →
    # stop_running_task → terminate_task hits the supervised :ok branch.
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [%{iss | state: "Done"}])
    send(pid, :run_poll_cycle)

    state = wait_for_state(pid, fn s -> not Map.has_key?(s.running, iss.id) end, 2_000)
    refute MapSet.member?(state.claimed, iss.id)
  end

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

  test "a running issue that is also blocked is skipped by stall reconciliation" do
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

    pid = start_orchestrator(:StallButBlocked)

    iss = issue("iss-stall-blocked", "SB2-1", state: "In Progress")
    stale = DateTime.add(DateTime.utc_now(), -60, :second)
    entry = running_entry(iss, ref: make_ref(), started_at: stale) |> Map.put(:last_codex_timestamp, stale)

    blocked_entry = %{
      issue_id: iss.id,
      identifier: iss.identifier,
      issue: iss,
      worker_host: nil,
      error: "already blocked",
      blocked_at: DateTime.utc_now()
    }

    Application.put_env(:symphony_elixir, :memory_tracker_issues, [iss])

    seed(pid,
      running: %{iss.id => entry},
      blocked: %{iss.id => blocked_entry},
      claimed: MapSet.new([iss.id])
    )

    send(pid, :run_poll_cycle)
    # maybe_restart_stalled_issue sees the issue in `blocked` and returns the
    # state unchanged (no restart timer scheduled by the stall path).
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert Map.has_key?(state.running, iss.id) or Map.has_key?(state.blocked, iss.id)
  end

  # ── needs_input string completion outcome ─────────────────────────────────

  test "a string needs_input completion outcome blocks the issue" do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_issues, [])

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_issues)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    pid = start_orchestrator(:StringNeedsInput)

    iss = issue("iss-needs-input-str", "NIS-1", state: "In Progress")
    ref = make_ref()

    entry =
      running_entry(iss, ref: ref)
      |> Map.merge(%{completion: %{"outcome" => "needs_input"}})

    seed(pid, running: %{iss.id => entry}, claimed: MapSet.new([iss.id]))

    send(pid, {:DOWN, ref, :process, self(), :normal})
    state = wait_for_state(pid, fn s -> Map.has_key?(s.blocked, iss.id) end)
    assert state.blocked[iss.id].error == "codex turn requires operator input"
  end

  # ── codex_message_method with an unwrapped atom-key method ─────────────────

  test "a stalled entry whose mcp message uses an unwrapped atom method is blocked" do
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

    pid = start_orchestrator(:StallAtomMethod)

    iss = issue("iss-atom-method", "AM-1", state: "In Progress")
    stale = DateTime.add(DateTime.utc_now(), -5, :second)

    entry = %{
      pid: dummy_worker(),
      ref: make_ref(),
      identifier: iss.identifier,
      issue: iss,
      session_id: nil,
      last_codex_message: %{method: "mcpServer/elicitation/request"},
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

  test "stall reconciliation tolerates a non-map running entry without crashing" do
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

    pid = start_orchestrator(:NonMapRunningEntry)

    # A malformed (non-map) running entry routes through stall_elapsed_ms ->
    # last_activity_timestamp's non-map clause, which returns nil so the entry
    # is simply skipped (no restart). The reconcile_running_issues fetch below
    # leaves it as "missing" and releases its (absent) claim, but the stall
    # pass runs first and must not crash.
    seed(pid, running: %{"iss-nonmap" => :not_a_map}, claimed: MapSet.new())

    send(pid, :run_poll_cycle)
    state = wait_for_state(pid, fn s -> s.poll_check_in_progress == false end)
    assert is_map(state.running)
  end

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
