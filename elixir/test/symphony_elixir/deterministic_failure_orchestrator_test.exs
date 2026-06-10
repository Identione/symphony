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
      Application.delete_env(:symphony_elixir, :memory_tracker_fetch_comments_delay_ms)
      Application.delete_env(:symphony_elixir, :memory_tracker_update_comment_delay_ms)
      Application.delete_env(:symphony_elixir, :memory_tracker_create_comment_delay_ms)
      Application.delete_env(:symphony_elixir, :memory_tracker_update_issue_state_delay_ms)
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
    # Suppress the initial auto-poll so it can't race the post-start seed below
    # and wipe running/claimed before our :DOWN event lands (IDE-131).
    {:ok, pid} = Orchestrator.start_link(name: name, poll_on_start: false)

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

  defp wait_for_state(pid, predicate, timeout_ms \\ 2_000) do
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

    # `:port_exit` is deterministic (IDE-73 counter advances) AND retryable
    # under IDE-72's policy (falls through to the `:unknown` bucket), so this
    # test exercises the streak-without-comment path while still letting the
    # orchestrator schedule a retry. `:quota_exceeded` would block immediately
    # under IDE-72 — see `OrchestratorRetryPolicyTest` for that coverage.
    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :port_exit, :anything}})

    wait_for_state(pid, fn s -> Map.has_key?(s.deterministic_failures, issue.id) end)
    state = :sys.get_state(pid)

    assert %{code: :port_exit, count: 1, notified_alert?: false, notified_escalation?: false} =
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

    assert_receive {:memory_tracker_comment_update, "workpad-orch-1", new_body}, 2_000
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

    assert_receive {:memory_tracker_comment_update, "workpad-orch-2", body}, 2_000
    assert body =~ "Deterministic-failure escalation"
    assert body =~ "**5** consecutive failures"

    assert_receive {:memory_tracker_state_update, "issue-det-orch", "Human Review"}, 2_000

    # Under the IDE-102 async hop, `escalate_running_issue/3` runs in the
    # `:deterministic_failure_result` handler after the Tracker round-trips
    # complete — so wait for `claimed` to drop (the last bit the handler
    # touches) rather than `running` (which is cleared on `:DOWN`).
    state =
      wait_for_state(pid, fn s ->
        not MapSet.member?(s.claimed, issue.id) and
          not Map.has_key?(s.pending_escalations, issue.id)
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

    assert_receive {:memory_tracker_comment, "issue-det-orch", blocker_body}, 2_000
    assert blocker_body =~ "Symphony Deterministic Failure Escalation"
    assert blocker_body =~ "Error code: `quota_exceeded`"
    assert blocker_body =~ "Consecutive failures: **5**"

    assert_receive {:memory_tracker_state_update, "issue-det-orch", "Human Review"}, 2_000
  end

  test "deterministic_codes/0 + decide/3 are exposed publicly so external callers can branch on them" do
    # Smoke test guarding the orchestrator's contract with DeterministicFailure.
    # Keep them aligned with the orchestrator's expectations.
    codes = DeterministicFailure.deterministic_codes()
    assert :quota_exceeded in codes
  end

  # ── IDE-74: max_turns_reached flows through the same surfacing pipeline ──
  #
  # `AgentRunner.run/3` exits with
  # `{:agent_run_failed, :max_turns_reached, :max_turns_reached}` when the
  # `agent.max_turns` cap is hit with the issue still active. The orchestrator
  # must treat that as a deterministic code so the counter advances, post a
  # workpad alert once `agent.deterministic_failure_alert_threshold` is
  # crossed, and escalate the issue out of the active set once
  # `agent.deterministic_failure_escalation_threshold` is crossed.
  describe "max_turns_reached :DOWN (IDE-74)" do
    test "a single :max_turns_reached :DOWN starts a streak and schedules a continuation retry",
         %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      pid = start_orchestrator(:MaxTurnsSingleFailureOrchestrator)
      ref = make_ref()
      seed_running(pid, issue.id, running_entry(issue, ref))

      send(
        pid,
        {:DOWN, ref, :process, self(), {:agent_run_failed, :max_turns_reached, :max_turns_reached}}
      )

      wait_for_state(pid, fn s -> Map.has_key?(s.deterministic_failures, issue.id) end)
      state = :sys.get_state(pid)

      assert %{code: :max_turns_reached, count: 1, notified_alert?: false, notified_escalation?: false} =
               state.deterministic_failures[issue.id]

      refute_received {:memory_tracker_comment, _, _}
      refute_received {:memory_tracker_state_update, _, _}

      # Cadence matches the existing continuation 1s re-poll, set via the
      # `RetryPolicy.built_in_for(:max_turns_reached, _)` clause.
      assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue.id]
      remaining = due_at_ms - System.monotonic_time(:millisecond)
      assert remaining in 800..1_200, "expected ~1s cadence, got #{remaining}ms"
    end

    test "after N=3 consecutive cap-hits a workpad alert comment is posted",
         %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        issue.id => [
          %{
            id: "workpad-max-turns-alert",
            body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do",
            resolved_at: nil
          }
        ]
      })

      pid = start_orchestrator(:MaxTurnsAlertOrchestrator)
      ref = make_ref()
      seed_running(pid, issue.id, running_entry(issue, ref))

      # Pre-seed the counter at N-1 so a single DOWN crosses the alert
      # threshold without spinning the GenServer through three full DOWN
      # cycles (each would schedule a retry timer we'd then have to ignore).
      seed_counter(pid, issue.id, %{
        code: :max_turns_reached,
        count: 2,
        notified_alert?: false,
        notified_escalation?: false
      })

      send(
        pid,
        {:DOWN, ref, :process, self(), {:agent_run_failed, :max_turns_reached, :max_turns_reached}}
      )

      assert_receive {:memory_tracker_comment_update, "workpad-max-turns-alert", new_body}, 2_000
      assert new_body =~ "Deterministic-failure alert"
      assert new_body =~ "**3** consecutive failures"
      assert new_body =~ "`max_turns_reached`"

      # Alert does not move state; escalation happens at the higher threshold.
      refute_received {:memory_tracker_state_update, _, _}

      state = :sys.get_state(pid)

      assert %{code: :max_turns_reached, count: 3, notified_alert?: true, notified_escalation?: false} =
               state.deterministic_failures[issue.id]
    end

    test "after M=5 consecutive cap-hits the issue is escalated out of the active set",
         %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        issue.id => [
          %{
            id: "workpad-max-turns-escalate",
            body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do",
            resolved_at: nil
          }
        ]
      })

      pid = start_orchestrator(:MaxTurnsEscalationOrchestrator)
      ref = make_ref()
      seed_running(pid, issue.id, running_entry(issue, ref))

      seed_counter(pid, issue.id, %{
        code: :max_turns_reached,
        count: 4,
        notified_alert?: true,
        notified_escalation?: false
      })

      send(
        pid,
        {:DOWN, ref, :process, self(), {:agent_run_failed, :max_turns_reached, :max_turns_reached}}
      )

      assert_receive {:memory_tracker_comment_update, "workpad-max-turns-escalate", body}, 2_000
      assert body =~ "Deterministic-failure escalation"
      assert body =~ "**5** consecutive failures"
      assert body =~ "`max_turns_reached`"
      assert_receive {:memory_tracker_state_update, "issue-det-orch", "Human Review"}, 2_000

      state =
        wait_for_state(pid, fn s ->
          not MapSet.member?(s.claimed, issue.id) and
            not Map.has_key?(s.pending_escalations, issue.id)
        end)

      refute Map.has_key?(state.running, issue.id)
      refute Map.has_key?(state.retry_attempts, issue.id)
      assert state.deterministic_failures[issue.id] == nil
    end

    test "an issue that moves out of active state mid-streak refuses to advance the counter",
         %{issue: issue} do
      # The cap-hit-then-issue-moves-out path is a clean `:ok` from
      # `AgentRunner` (the orchestrator never sees `:max_turns_reached` —
      # IDE-74 returns `:ok` from the `{:done, _}` arm). The `:normal` :DOWN
      # therefore must clear the counter, matching the existing
      # "a :normal exit clears any in-flight deterministic streak" test.
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})
      pid = start_orchestrator(:MaxTurnsThenMovedOutOrchestrator)
      ref = make_ref()
      seed_running(pid, issue.id, running_entry(issue, ref))

      seed_counter(pid, issue.id, %{
        code: :max_turns_reached,
        count: 2,
        notified_alert?: false,
        notified_escalation?: false
      })

      send(pid, {:DOWN, ref, :process, self(), :normal})

      wait_for_state(pid, fn s -> not Map.has_key?(s.deterministic_failures, issue.id) end)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.deterministic_failures, issue.id)
      assert MapSet.member?(state.completed, issue.id)
      refute_received {:memory_tracker_comment, _, _}
      refute_received {:memory_tracker_comment_update, _, _}
      refute_received {:memory_tracker_state_update, _, _}
    end
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

    # `:port_exit` is the test stand-in for a deterministic code that IDE-72
    # still allows the orchestrator to retry (`:quota_exceeded` blocks on
    # first failure under the IDE-72 policy and would short-circuit the retry
    # rescheduling this test wants to exercise).
    seed_counter(pid, issue.id, %{
      code: :port_exit,
      count: 4,
      notified_alert?: true,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :port_exit, :anything}})

    # Comment posts (sentinel-bounded; subsequent failures will replace it),
    # but the state move failed → both flags must stay in the state where the
    # next deterministic failure with the same code re-fires the escalation
    # path through `decide/3`.
    assert_receive {:memory_tracker_comment_update, "workpad-esc-retry", _body}, 2_000

    # Under the IDE-102 async hop the counter is persisted on `:DOWN` but the
    # retry is scheduled by the `:deterministic_failure_result` handler only
    # after the state-move failure surfaces. Wait for retry_attempts to land
    # so the assertions below see the post-handler state.
    state =
      wait_for_state(pid, fn s ->
        match?(%{count: 5}, s.deterministic_failures[issue.id]) and
          Map.has_key?(s.retry_attempts, issue.id)
      end)

    assert %{count: 5, notified_alert?: true, notified_escalation?: false} =
             state.deterministic_failures[issue.id]

    # Sanity: a subsequent decide/3 with the same code returns :escalate again
    # because notified_escalation? is still false.
    settings = SymphonyElixir.Config.settings!()

    assert {%{count: 6}, {:escalate, :port_exit, 6}} =
             DeterministicFailure.decide(
               state.deterministic_failures[issue.id],
               :port_exit,
               settings
             )

    # The orchestrator's retry loop puts the issue back in retry_attempts (it
    # was popped from `running` before the deterministic-failure branch ran);
    # this is the existing retry path doing its job.
    refute Map.has_key?(state.running, issue.id)
    assert Map.has_key?(state.retry_attempts, issue.id)
  end

  # ── IDE-102: async escalation ────────────────────────────────────────────
  #
  # `DeterministicFailure.handle/3` runs under `SymphonyElixir.TaskSupervisor`,
  # so a slow/blocked Linear API call cannot stall dispatch for other issues.
  # These tests pin down the contract: the GenServer stays responsive while
  # the side effect is in flight, the counter/flag persistence contract from
  # IDE-73 is preserved, and the state-move + drop guarantee still holds
  # across the async hop.

  defp put_workpad(issue_id, comment_id) do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      issue_id => [
        %{
          id: comment_id,
          body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do",
          resolved_at: nil
        }
      ]
    })
  end

  defp set_tracker_delays(ms) do
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_comments_delay_ms, ms)
    Application.put_env(:symphony_elixir, :memory_tracker_update_comment_delay_ms, ms)
    Application.put_env(:symphony_elixir, :memory_tracker_update_issue_state_delay_ms, ms)
  end

  test "issue A's slow escalation does not block issue B's :DOWN from advancing on the GenServer",
       %{issue: issue} do
    issue_b = %{issue | id: "issue-det-orch-b", identifier: "DET-2"}

    put_workpad(issue.id, "workpad-a")
    # ~300ms total delay on the escalation path for issue A.
    set_tracker_delays(100)

    pid = start_orchestrator(:AsyncMultiIssueOrchestrator)
    ref_a = make_ref()
    ref_b = make_ref()

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{
        issue.id => running_entry(issue, ref_a),
        issue_b.id => running_entry(issue_b, ref_b)
      })
      |> Map.put(:claimed, MapSet.new([issue.id, issue_b.id]))
      |> Map.put(:retry_attempts, %{})
      |> Map.put(:deterministic_failures, %{
        issue.id => %{
          code: :quota_exceeded,
          count: 4,
          notified_alert?: true,
          notified_escalation?: false
        }
      })
    end)

    # Issue A: cross the escalation threshold → slow async side effect.
    send(pid, {:DOWN, ref_a, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    # Issue B: a transient code that should reset its (empty) counter and
    # schedule a retry. If the orchestrator were blocked on A's Linear
    # round-trips, B's DOWN would queue behind them and this assertion would
    # take ~300ms.
    send(pid, {:DOWN, ref_b, :process, self(), {:agent_run_failed, :rate_limited, :anything}})

    advanced_at_ms =
      time_until(fn ->
        s = :sys.get_state(pid)
        Map.has_key?(s.retry_attempts, issue_b.id) and not Map.has_key?(s.running, issue_b.id)
      end)

    assert advanced_at_ms < 100,
           "issue B's :DOWN waited on issue A's escalation side effect; advanced in #{advanced_at_ms}ms"

    # Eventually A's escalation lands and drops it from claimed/running.
    state =
      wait_for_state(
        pid,
        fn s ->
          not Map.has_key?(s.pending_escalations, issue.id) and
            not Map.has_key?(s.running, issue.id)
        end,
        2_000
      )

    refute MapSet.member?(state.claimed, issue.id)
    refute Map.has_key?(state.deterministic_failures, issue.id)
  end

  test "while an escalation task is in flight, the issue stays in `claimed` and out of `running`/`retry_attempts`",
       %{issue: issue} do
    put_workpad(issue.id, "workpad-inflight")
    # Delay the very first Tracker call so we have a window to observe the
    # in-flight state before any side effect lands.
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_comments_delay_ms, 200)

    pid = start_orchestrator(:AsyncInflightStateOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 4,
      notified_alert?: true,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    inflight =
      wait_for_state(pid, fn s -> Map.has_key?(s.pending_escalations, issue.id) end)

    refute Map.has_key?(inflight.running, issue.id),
           "issue is popped from running on :DOWN"

    assert MapSet.member?(inflight.claimed, issue.id),
           "issue stays in `claimed` so the polling loop won't re-dispatch it while the escalation task is in flight"

    refute Map.has_key?(inflight.retry_attempts, issue.id),
           "no retry timer is scheduled until the result handler decides (escalate=drop, alert/error=retry)"

    # Let the in-flight side effect complete so the stray messages don't leak
    # past on_exit cleanup.
    assert_receive {:memory_tracker_comment_update, "workpad-inflight", _}, 2_000
    assert_receive {:memory_tracker_state_update, "issue-det-orch", "Human Review"}, 2_000
  end

  test "release_issue_claim wipes pending_escalations so a late result is a no-op", %{issue: issue} do
    put_workpad(issue.id, "workpad-late")
    Application.put_env(:symphony_elixir, :memory_tracker_fetch_comments_delay_ms, 200)

    pid = start_orchestrator(:LateResultOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    seed_counter(pid, issue.id, %{
      code: :quota_exceeded,
      count: 2,
      notified_alert?: false,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :quota_exceeded, :anything}})

    pending =
      wait_for_state(pid, fn s -> Map.has_key?(s.pending_escalations, issue.id) end).pending_escalations[
        issue.id
      ]

    # Simulate an external path wiping the claim mid-flight (e.g. the issue
    # moved to a terminal state via reconciliation). The pending entry must
    # be dropped so the in-flight task's eventual result is ignored.
    :sys.replace_state(pid, fn state ->
      %{
        state
        | claimed: MapSet.delete(state.claimed, issue.id),
          retry_attempts: Map.delete(state.retry_attempts, issue.id),
          pending_escalations: Map.delete(state.pending_escalations, issue.id),
          deterministic_failures: Map.delete(state.deterministic_failures, issue.id)
      }
    end)

    # Forge a stale result message with the original token. The orchestrator
    # should drop it because pending_escalations no longer has an entry.
    send(
      pid,
      {:deterministic_failure_result, issue.id, pending.token, {:alert, :quota_exceeded, 3}, :ok}
    )

    state = :sys.get_state(pid)
    refute Map.has_key?(state.deterministic_failures, issue.id)
    refute Map.has_key?(state.pending_escalations, issue.id)
    refute Map.has_key?(state.retry_attempts, issue.id)

    # Drain the late side-effect message so it doesn't leak into the next test.
    receive do
      {:memory_tracker_comment_update, "workpad-late", _} -> :ok
    after
      2_000 -> flunk("expected the in-flight side effect to eventually fire")
    end
  end

  test "a task crash surfaces as an :error result and keeps the counter retryable", %{issue: issue} do
    pid = start_orchestrator(:TaskCrashOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    # `:port_exit` is deterministic (IDE-73) AND still retryable under the
    # IDE-72 policy. Picking `:quota_exceeded` here would block the issue
    # before the retry rescheduling this test asserts.
    pending = %{
      token: make_ref(),
      action: {:alert, :port_exit, 3},
      entry: %{code: :port_exit, count: 3, notified_alert?: false, notified_escalation?: false},
      running_entry: running_entry(issue, ref),
      reason: {:agent_run_failed, :port_exit, :anything}
    }

    :sys.replace_state(pid, fn state ->
      %{
        state
        | running: %{},
          claimed: MapSet.put(state.claimed, issue.id),
          deterministic_failures: Map.put(state.deterministic_failures, issue.id, pending.entry),
          pending_escalations: Map.put(state.pending_escalations, issue.id, pending)
      }
    end)

    send(
      pid,
      {:deterministic_failure_result, issue.id, pending.token, pending.action, {:error, {:task_crashed, :error, %RuntimeError{message: "boom"}, []}}}
    )

    state =
      wait_for_state(pid, fn s -> Map.has_key?(s.retry_attempts, issue.id) end)

    # Flags stay clear so the next same-code :DOWN re-fires the alert path
    # via `decide/3` (IDE-73 retry contract preserved across the async hop).
    assert %{code: :port_exit, count: 3, notified_alert?: false, notified_escalation?: false} =
             state.deterministic_failures[issue.id]

    refute Map.has_key?(state.pending_escalations, issue.id)
    assert Map.has_key?(state.retry_attempts, issue.id)
  end

  test "a failed side-effect spawn persists the counter, leaves flags clear, and schedules a retry without a pending escalation",
       %{issue: issue} do
    Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
      issue.id => [
        %{
          id: "workpad-spawn-fail",
          body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do",
          resolved_at: nil
        }
      ]
    })

    # Force `Task.Supervisor.start_child/2` to return `{:error, :max_children}`
    # by pointing the orchestrator's deterministic-action supervisor at a
    # test-local Task.Supervisor capped at zero children.
    {:ok, full_sup} = Task.Supervisor.start_link(max_children: 0)

    Application.put_env(:symphony_elixir, :deterministic_action_task_supervisor, full_sup)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :deterministic_action_task_supervisor)
      # Race-safe: on_exit runs after the test process (which the capped
      # supervisor is linked to) starts tearing down. :kill is a no-op on an
      # already-dead pid, avoiding the GenServer.stop "no process" exit.
      Process.exit(full_sup, :kill)
    end)

    pid = start_orchestrator(:SpawnFailureOrchestrator)
    ref = make_ref()
    seed_running(pid, issue.id, running_entry(issue, ref))

    # Pre-seed at N-1 so a single DOWN crosses the alert threshold and tries to
    # spawn the side effect — which then fails because the supervisor is full.
    # `:port_exit` is deterministic (counter advances) AND retryable under the
    # IDE-72 policy, so this test can assert the retry is still scheduled when
    # the spawn fails; `:quota_exceeded` would block on first failure.
    seed_counter(pid, issue.id, %{
      code: :port_exit,
      count: 2,
      notified_alert?: false,
      notified_escalation?: false
    })

    send(pid, {:DOWN, ref, :process, self(), {:agent_run_failed, :port_exit, :anything}})

    state =
      wait_for_state(pid, fn s ->
        match?(%{count: 3}, s.deterministic_failures[issue.id]) and
          Map.has_key?(s.retry_attempts, issue.id)
      end)

    # Counter advanced to 3 but both notification flags stay clear because the
    # side effect never ran (the spawn failed before `handle/3`).
    assert %{code: :port_exit, count: 3, notified_alert?: false, notified_escalation?: false} =
             state.deterministic_failures[issue.id]

    # No pending escalation entry is left behind — the spawn never succeeded.
    refute Map.has_key?(state.pending_escalations, issue.id)

    # The issue falls through to the existing retry path.
    assert Map.has_key?(state.retry_attempts, issue.id)

    # The full supervisor never accepted a child, so no side-effect message fired.
    refute_received {:memory_tracker_comment_update, "workpad-spawn-fail", _}
    refute_received {:memory_tracker_state_update, _, _}
  end

  # Tight loop that polls `fun` until it returns truthy and reports how long
  # it took. Used to assert the orchestrator GenServer remains responsive
  # while a `DeterministicFailure` side effect runs under the Task supervisor.
  defp time_until(fun, timeout_ms \\ 1_000) do
    start = System.monotonic_time(:millisecond)
    deadline = start + timeout_ms
    do_time_until(fun, start, deadline)
  end

  defp do_time_until(fun, start, deadline) do
    if fun.() do
      System.monotonic_time(:millisecond) - start
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("timed out waiting for predicate to become truthy")
      else
        Process.sleep(2)
        do_time_until(fun, start, deadline)
      end
    end
  end
end
