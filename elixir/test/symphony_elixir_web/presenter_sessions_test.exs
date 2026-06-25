defmodule SymphonyElixirWeb.PresenterSessionsTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.{Linear.Issue, Orchestrator}
  alias SymphonyElixirWeb.Presenter

  # Builds an orchestrator carrying one running, one retrying, and one blocked
  # issue, then projects it through the presenter. Exercises the unified
  # `sessions` list the dashboard renders.
  defp orchestrator_with_sessions do
    name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    running_issue = %Issue{id: "run-1", identifier: "MT-1", title: "Run", state: "In Progress"}
    blocked_issue = %Issue{id: "blk-1", identifier: "MT-3", title: "Blocked", state: "Merging"}

    running_entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: "MT-1",
      issue: running_issue,
      session_id: "sess-run-1",
      turn_count: 2,
      codex_input_tokens: 10,
      codex_output_tokens: 4,
      codex_total_tokens: 14,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      started_at: DateTime.utc_now()
    }

    retry_entry = %{
      attempt: 2,
      due_at_ms: System.monotonic_time(:millisecond) + 30_000,
      identifier: "MT-2",
      error: "transient boom"
    }

    blocked_entry = %{
      identifier: "MT-3",
      issue: blocked_issue,
      session_id: "sess-blk-1",
      error: "no retry for permanent_failure",
      blocked_at: DateTime.utc_now(),
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil
    }

    state =
      pid
      |> :sys.get_state()
      |> Map.put(:running, %{"run-1" => running_entry})
      |> Map.put(:retry_attempts, %{"ret-1" => retry_entry})
      |> Map.put(:blocked, %{"blk-1" => blocked_entry})

    :sys.replace_state(pid, fn _ -> state end)
    name
  end

  test "sessions merges running, retrying, and blocked in priority order" do
    payload = Presenter.state_payload(orchestrator_with_sessions(), 5_000)

    assert [running, retrying, blocked] = payload.sessions
    assert running.status == :running
    assert retrying.status == :retrying
    assert blocked.status == :blocked

    assert running.issue_identifier == "MT-1"
    assert retrying.issue_identifier == "MT-2"
    assert blocked.issue_identifier == "MT-3"
  end

  test "per-status fields are carried for the dashboard columns" do
    payload = Presenter.state_payload(orchestrator_with_sessions(), 5_000)
    [running, retrying, blocked] = payload.sessions

    # tokens only on the running row; absent (nil) on retry/blocked
    assert running.tokens.total_tokens == 14
    refute Map.get(retrying, :tokens)
    refute Map.get(blocked, :tokens)

    # the time/description sources each status uses
    assert running.started_at
    assert retrying.attempt == 2
    assert retrying.error == "transient boom"
    assert blocked.blocked_at
    assert blocked.error == "no retry for permanent_failure"
    assert blocked.session_id == "sess-blk-1"
  end

  test "original running/retrying/blocked keys remain for the JSON API" do
    payload = Presenter.state_payload(orchestrator_with_sessions(), 5_000)

    assert length(payload.running) == 1
    assert length(payload.retrying) == 1
    assert length(payload.blocked) == 1

    assert payload.counts == %{
             running: 1,
             retrying: 1,
             blocked: 1,
             dependency_blocked: 0,
             awaiting_merge: 0
           }
  end
end
