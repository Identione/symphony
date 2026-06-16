defmodule SymphonyElixir.OrchestratorSessionBudgetTest do
  @moduledoc """
  Drives the orchestrator's clean-exit (`:normal`) continuation path and asserts
  the cumulative per-issue session cap (P1/R1(a)):

    1. Cap — once an issue has run `agent.max_sessions_per_issue` sessions while
       staying active, the next clean exit escalates via the DeterministicFailure
       machinery instead of scheduling another continuation.
    2. Restart-durable — a counter loaded from the on-disk DETS store (no
       in-memory history) still trips the cap.
    3. Episode reset — escalation zeroes the count and advances the generation so
       a re-entry gets a fresh budget rather than re-escalating off the stale tally.

  Uses the memory tracker so the escalation's comment + state-move land as
  messages on the test process.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator.SessionBudget

  setup do
    path = Workflow.workflow_file_path()
    content = File.read!(path)
    File.write!(path, String.replace(content, ~s(kind: "linear"), ~s(kind: "memory")))

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      SymphonyElixir.WorkflowStore.force_reload()
    end

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_comments)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
      Application.delete_env(:symphony_elixir, :session_budget_file)
    end)

    issue = %Issue{
      id: "issue-budget",
      identifier: "BUD-1",
      title: "Poll-only loop",
      state: "In Progress",
      url: "https://example.org/issues/BUD-1"
    }

    cap = SymphonyElixir.Config.settings!().agent.max_sessions_per_issue

    {:ok, issue: issue, cap: cap}
  end

  defp start_orchestrator(label) do
    name = Module.concat(__MODULE__, label)
    {:ok, pid} = Orchestrator.start_link(name: name, poll_on_start: false)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  defp running_entry(issue, ref) do
    %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: "sess-#{issue.identifier}",
      retry_attempt: 0,
      started_at: DateTime.utc_now()
    }
  end

  defp seed_running(pid, issue_id, running_entry) do
    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
      |> Map.put(:retry_attempts, %{})
      |> Map.put(:deterministic_failures, %{})
      |> Map.put(:pending_escalations, %{})
    end)
  end

  defp seed_session_count(pid, issue_id, entry) do
    :sys.replace_state(pid, fn state ->
      Map.put(state, :session_counts, Map.put(state.session_counts, issue_id, entry))
    end)
  end

  defp wait_for_state(pid, predicate, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_state(pid, predicate, deadline)
  end

  defp do_wait_for_state(pid, predicate, deadline) do
    state = :sys.get_state(pid)

    cond do
      predicate.(state) -> state
      System.monotonic_time(:millisecond) >= deadline -> flunk("timed out: #{inspect(state)}")
      true -> Process.sleep(5) && do_wait_for_state(pid, predicate, deadline)
    end
  end

  test "a clean exit at the session cap escalates instead of continuing", %{issue: issue, cap: cap} do
    pid = start_orchestrator(:CapOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))
    seed_session_count(pid, issue.id, %{generation: 1, count: cap})

    send(pid, {:DOWN, ref, :process, self(), :normal})

    assert_receive {:memory_tracker_state_update, "issue-budget", "Human Review"}, 2_000

    state =
      wait_for_state(pid, fn s ->
        not MapSet.member?(s.claimed, issue.id) and
          not Map.has_key?(s.pending_escalations, issue.id)
      end)

    refute Map.has_key?(state.running, issue.id)

    refute Map.has_key?(state.retry_attempts, issue.id),
           "the capped issue must NOT get another continuation retry"
  end

  test "a clean exit below the cap still schedules a continuation", %{issue: issue, cap: cap} do
    pid = start_orchestrator(:UnderCapOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))
    seed_session_count(pid, issue.id, %{generation: 1, count: cap - 1})

    send(pid, {:DOWN, ref, :process, self(), :normal})

    state = wait_for_state(pid, fn s -> Map.has_key?(s.retry_attempts, issue.id) end)
    assert %{attempt: 1} = state.retry_attempts[issue.id]
    refute_received {:memory_tracker_state_update, "issue-budget", _}
  end

  test "a count loaded from the DETS store survives a restart and still trips the cap",
       %{issue: issue, cap: cap} do
    dets_path =
      Path.join(System.tmp_dir!(), "symphony_session_budget_test_#{System.unique_integer([:positive])}.dets")

    on_exit(fn -> File.rm(dets_path) end)

    # Pre-seed the durable store at the cap via the module's own API, then close
    # it — the orchestrator must re-open and load it cold (empty in-memory).
    {table, _} = SessionBudget.open(dets_path)
    :ok = SessionBudget.put(table, issue.id, %{generation: 1, count: cap})
    :ok = SessionBudget.close(table)

    Application.put_env(:symphony_elixir, :session_budget_file, dets_path)

    pid = start_orchestrator(:RestartOrchestrator)
    # The freshly started orchestrator must have loaded the count from disk.
    assert %{count: ^cap} = :sys.get_state(pid).session_counts[issue.id]

    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))
    send(pid, {:DOWN, ref, :process, self(), :normal})

    assert_receive {:memory_tracker_state_update, "issue-budget", "Human Review"}, 2_000
  end

  test "escalation resets the episode so a re-entry gets a fresh budget", %{issue: issue, cap: cap} do
    pid = start_orchestrator(:ResetOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))
    seed_session_count(pid, issue.id, %{generation: 1, count: cap})

    send(pid, {:DOWN, ref, :process, self(), :normal})
    assert_receive {:memory_tracker_state_update, "issue-budget", "Human Review"}, 2_000

    state =
      wait_for_state(pid, fn s -> not MapSet.member?(s.claimed, issue.id) end)

    # Generation advanced, count zeroed — the stale tally can't re-escalate.
    assert %{generation: 2, count: 0} = state.session_counts[issue.id]

    # Re-entry (human moved it back to Todo): a fresh clean exit now continues
    # rather than escalating, proving the budget reset.
    ref2 = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref2))
    send(pid, {:DOWN, ref2, :process, self(), :normal})

    state2 = wait_for_state(pid, fn s -> Map.has_key?(s.retry_attempts, issue.id) end)
    assert %{attempt: 1} = state2.retry_attempts[issue.id]
  end
end
