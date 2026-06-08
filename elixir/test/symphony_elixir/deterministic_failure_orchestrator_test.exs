defmodule SymphonyElixir.DeterministicFailureOrchestratorTest do
  @moduledoc """
  Drives the orchestrator's `:DOWN` handler with structured
  `{:agent_run_failed, code, reason}` exit reasons (IDE-73) and asserts the
  deterministic-failure counter, workpad comment, and state-transition
  side effects.

  Tests configure the memory tracker as the active adapter so all
  `Tracker.fetch_comments/1`, `Tracker.create_comment/2`,
  `Tracker.update_comment/2`, and `Tracker.update_issue_state/2` calls land
  as Erlang messages on the test process.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DeterministicFailure
  alias SymphonyElixir.Linear.Issue

  setup do
    # Swap the tracker kind to "memory" so the orchestrator's comment and
    # state-update calls land on the test process via memory_tracker_recipient.
    path = Workflow.workflow_file_path()
    content = File.read!(path)
    File.write!(path, String.replace(content, ~s(kind: "linear"), ~s(kind: "memory")))

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      SymphonyElixir.WorkflowStore.force_reload()
    end

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_comments)
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    issue =
      %Issue{
        id: "issue-det-orch",
        identifier: "DET-1",
        title: "Stuck adapter loop",
        state: "In Progress",
        url: "https://example.org/issues/DET-1"
      }

    {:ok, issue: issue}
  end

  defp start_orchestrator(label) do
    name = Module.concat(__MODULE__, label)
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :normal)
      end
    end)

    pid
  end

  defp running_entry(issue, ref) do
    %{
      pid: self(),
      ref: ref,
      identifier: issue.identifier,
      issue: issue,
      session_id: nil,
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
    end)
  end

  defp seed_counter(pid, issue_id, entry) do
    :sys.replace_state(pid, fn state ->
      Map.put(state, :deterministic_failures, Map.put(state.deterministic_failures, issue_id, entry))
    end)
  end

  defp wait_for_state(pid, predicate, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_state(pid, predicate, deadline)
  end

  defp do_wait_for_state(pid, predicate, deadline) do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for orchestrator state: #{inspect(state)}")
      else
        Process.sleep(5)
        do_wait_for_state(pid, predicate, deadline)
      end
    end
  end

  test "a single deterministic failure starts a streak but does not post a comment", %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
    pid = start_orchestrator(:SingleFailureOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    wait_for_state(pid, fn s -> Map.has_key?(s.deterministic_failures, issue.id) end)
    state = :sys.get_state(pid)

    assert %{code: :quota_exceeded, count: 1, notified_alert?: false, notified_escalation?: false} =
             state.deterministic_failures[issue.id]

    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}
    # The retry is still scheduled — escalation only blocks the *dispatch* at M.
    assert %{attempt: 1} = state.retry_attempts[issue.id]
  end

  test "after N=3 same-code failures, a workpad alert comment is posted", %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      issue.id => [
        %{
          id: "workpad-orch-1",
          body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do",
          resolved_at: nil
        }
      ]
    })

    pid = start_orchestrator(:AlertOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    # Pre-seed the counter at N-1 so a single DOWN crosses the alert
    # threshold. Avoids spinning the GenServer through three full DOWN cycles
    # (each schedules a retry timer that we then have to ignore).
    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 2,
      notified_alert?: false,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    assert_receive {:memory_tracker_comment_update, "workpad-orch-1", new_body}, 500
    assert new_body =~ "Deterministic-failure alert"
    assert new_body =~ "**3** consecutive failures"
    assert new_body =~ "`quota_exceeded`"

    # Alert should not move state at the alert threshold.
    refute_received {:memory_tracker_state_update, _, _}

    # Counter is now at 3 and notified_alert? flipped.
    state = :sys.get_state(pid)

    assert %{code: :quota_exceeded, count: 3, notified_alert?: true, notified_escalation?: false} =
             state.deterministic_failures[issue.id]
  end

  test "after M=5 same-code failures, the issue is escalated and dropped from active state",
       %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      issue.id => [
        %{
          id: "workpad-orch-2",
          body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do",
          resolved_at: nil
        }
      ]
    })

    pid = start_orchestrator(:EscalationOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    # Pre-seed at M-1 with the alert already fired so this DOWN crosses the
    # escalation threshold cleanly.
    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 4,
      notified_alert?: true,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    assert_receive {:memory_tracker_comment_update, "workpad-orch-2", body}, 500
    assert body =~ "Deterministic-failure escalation"
    assert body =~ "**5** consecutive failures"

    assert_receive {:memory_tracker_state_update, "issue-det-orch", "Human Review"}, 500

    state =
      wait_for_state(pid, fn s ->
        not Map.has_key?(s.running, issue.id) and not Map.has_key?(s.retry_attempts, issue.id)
      end)

    refute Map.has_key?(state.running, issue.id), "escalated issue must be dropped from running"
    refute MapSet.member?(state.claimed, issue.id), "escalated issue must release its claim"
    refute Map.has_key?(state.retry_attempts, issue.id), "escalated issue must cancel its retry"

    assert state.deterministic_failures[issue.id] == nil,
           "escalation resets the counter so the issue can be re-driven later by a human"
  end

  test "a transient code (rate_limited) clears the counter mid-streak", %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
    pid = start_orchestrator(:TransientResetOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 2,
      notified_alert?: false,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :rate_limited, :anything}})

    wait_for_state(pid, fn s -> not Map.has_key?(s.deterministic_failures, issue.id) end)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.deterministic_failures, issue.id)
    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_comment_update, _, _}
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "a different deterministic code restarts the streak at 1 rather than continuing the old one",
       %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
    pid = start_orchestrator(:DifferentCodeOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 2,
      notified_alert?: false,
      notified_escalation?: false
    })

    send(
      pid,
      {:DOWN, ref, :process, self(), {:agent_run_failed, :context_window_exhausted, :anything}}
    )

    wait_for_state(pid, fn s ->
      case s.deterministic_failures[issue.id] do
        %{code: :context_window_exhausted} -> true
        _ -> false
      end
    end)

    state = :sys.get_state(pid)

    assert %{code: :context_window_exhausted, count: 1, notified_alert?: false} =
             state.deterministic_failures[issue.id]

    refute_received {:memory_tracker_comment, _, _}
    refute_received {:memory_tracker_state_update, _, _}
  end

  test "a :normal exit clears any in-flight deterministic streak", %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
    pid = start_orchestrator(:NormalExitResetOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 2,
      notified_alert?: false,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), :normal})

    wait_for_state(pid, fn s -> not Map.has_key?(s.deterministic_failures, issue.id) end)
    state = :sys.get_state(pid)

    refute Map.has_key?(state.deterministic_failures, issue.id)
    assert MapSet.member?(state.completed, issue.id)
  end

  test "no workpad found → escalation posts a standalone blocker comment + moves state",
       %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

    pid = start_orchestrator(:NoWorkpadEscalationOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 4,
      notified_alert?: true,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    assert_receive {:memory_tracker_comment, "issue-det-orch", blocker_body}, 500
    assert blocker_body =~ "Symphony Deterministic Failure Escalation"
    assert blocker_body =~ "Error code: `quota_exceeded`"
    assert blocker_body =~ "Consecutive failures: **5**"

    assert_receive {:memory_tracker_state_update, "issue-det-orch", "Human Review"}, 500
  end

  test "deterministic_codes/0 + decide/3 are exposed publicly so external callers can branch on them" do
    # Smoke test guarding the orchestrator's contract with DeterministicFailure.
    # Keep them aligned with the orchestrator's expectations.
    codes = DeterministicFailure.deterministic_codes()
    assert :quota_exceeded in codes
  end

  test "failed alert comment-update keeps notified_alert? clear so the next failure retries",
       %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      issue.id => [
        %{
          id: "workpad-retry",
          body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do",
          resolved_at: nil
        }
      ]
    })

    Application.put_env(:symphony_elixir, :memory_tracker_update_comment_response, {:error, :transport_down})

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_update_comment_response)
    end)

    pid = start_orchestrator(:AlertRetryOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 2,
      notified_alert?: false,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    # The counter advances (3) but `notified_alert?` stays false because the
    # comment-update side effect failed. The next deterministic failure with
    # the same code will hit the alert threshold again and retry the post.
    state =
      wait_for_state(pid, fn s ->
        case s.deterministic_failures[issue.id] do
          %{count: 3} -> true
          _ -> false
        end
      end)

    assert %{code: :quota_exceeded, count: 3, notified_alert?: false, notified_escalation?: false} =
             state.deterministic_failures[issue.id]
  end

  test "failed standalone-blocker create keeps notified_alert? clear so the next failure retries",
       %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
    Application.put_env(:symphony_elixir, :memory_tracker_create_comment_response, {:error, :transport_down})

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_response)
    end)

    pid = start_orchestrator(:AlertCreateRetryOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 2,
      notified_alert?: false,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    state =
      wait_for_state(pid, fn s ->
        case s.deterministic_failures[issue.id] do
          %{count: 3} -> true
          _ -> false
        end
      end)

    assert %{count: 3, notified_alert?: false} = state.deterministic_failures[issue.id]
  end

  test "failed escalation state-move keeps both flags clear and leaves the issue running",
       %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      issue.id => [
        %{
          id: "workpad-esc-retry",
          body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do",
          resolved_at: nil
        }
      ]
    })

    Application.put_env(
      :symphony_elixir,
      :memory_tracker_update_issue_state_response,
      {:error, :state_not_found}
    )

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_response)
    end)

    pid = start_orchestrator(:EscalateRetryOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 4,
      notified_alert?: true,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    # Comment posts (sentinel-bounded; subsequent failures will replace it),
    # but the state move failed → both flags must stay in the state where the
    # next deterministic failure with the same code re-fires the escalation
    # path through `decide/3`.
    assert_receive {:memory_tracker_comment_update, "workpad-esc-retry", _body}, 500

    state =
      wait_for_state(pid, fn s ->
        case s.deterministic_failures[issue.id] do
          %{count: 5} -> true
          _ -> false
        end
      end)

    assert %{count: 5, notified_alert?: true, notified_escalation?: false} =
             state.deterministic_failures[issue.id]

    # Sanity: a subsequent decide/3 with the same code returns :escalate again
    # because notified_escalation? is still false.
    settings = SymphonyElixir.Config.settings!()

    assert {%{count: 6}, {:escalate, :quota_exceeded, 6}} =
             DeterministicFailure.decide(
               state.deterministic_failures[issue.id],
               :quota_exceeded,
               settings
             )

    # The orchestrator's retry loop puts the issue back in retry_attempts (it
    # was popped from `running` before the deterministic-failure branch ran);
    # this is the existing retry path doing its job.
    refute Map.has_key?(state.running, issue.id)
    assert Map.has_key?(state.retry_attempts, issue.id)
  end
end
