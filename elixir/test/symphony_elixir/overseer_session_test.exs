defmodule SymphonyElixir.Overseer.SessionTest do
  @moduledoc """
  Run-scoped overseer state (IDE-212): the bounded transcript ring buffer and the
  call bookkeeping (`calls` / `last_call_turn`) that backs the cooldown + cap.
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.Overseer.Session

  defp env(n), do: %{event: :assistant_message, payload: %{text: "m#{n}"}}

  test "keeps only the last `window` envelopes, oldest-first" do
    {:ok, pid} = Session.start_link(3)
    for n <- 1..5, do: Session.record(pid, env(n))

    texts = pid |> Session.transcript() |> Enum.map(& &1.payload.text)
    assert texts == ["m3", "m4", "m5"]
  end

  test "a zero window records nothing" do
    {:ok, pid} = Session.start_link(0)
    Session.record(pid, env(1))
    assert Session.transcript(pid) == []
  end

  test "call bookkeeping bumps calls and tracks the last call turn" do
    {:ok, pid} = Session.start_link(10)
    assert %{calls: 0, last_call_turn: nil} = Session.stats(pid)

    Session.register_call(pid, 16)
    assert %{calls: 1, last_call_turn: 16} = Session.stats(pid)

    Session.register_call(pid, 19)
    assert %{calls: 2, last_call_turn: 19} = Session.stats(pid)
  end

  test "stop/1 tears the session down" do
    {:ok, pid} = Session.start_link(1)
    assert :ok = Session.stop(pid)
    refute Process.alive?(pid)
  end

  describe "Layer-1 progress state (IDE-230)" do
    # Minimal settings the pure ProgressSignal core reads: K and the revisit
    # window. Avoids depending on a booted WorkflowStore in this async case.
    defp settings,
      do: %{
        agent: %{
          progress_signal_window_k: 4,
          progress_trigger_min_turns: 4,
          progress_signal_revisit_window: 10
        }
      }

    defp obs(hash, empty, commits, turn),
      do: %{hash: hash, empty: empty, commits_since: commits, error_sig: nil, turn_count: turn}

    test "dispatch_head is captured once on the first probe and then sticks" do
      {:ok, pid} = Session.start_link(1)
      assert Session.dispatch_head(pid) == nil

      Session.capture_dispatch_head(pid, "sha-1")
      assert Session.dispatch_head(pid) == "sha-1"

      # A later probe must not overwrite the captured marker.
      Session.capture_dispatch_head(pid, "sha-2")
      assert Session.dispatch_head(pid) == "sha-1"
    end

    test "advance_progress increments the fail streak on tripping turns and resets on a passing turn" do
      {:ok, pid} = Session.start_link(1)

      # Identical clean tree: trips once the streak reaches K=4 (:stuck_state),
      # so turns 1-3 pass (streak 0) and turns 4-7 trip (streak 1..4).
      streaks =
        for t <- 1..7 do
          %{fail_streak: streak} = Session.advance_progress(pid, obs("same", true, 0, t), settings())
          streak
        end

      assert streaks == [0, 0, 0, 1, 2, 3, 4]

      # A healthy turn (distinct hash, fresh commit) resets the streak.
      %{fail_streak: streak} = Session.advance_progress(pid, obs("new", false, 1, 8), settings())
      assert streak == 0
    end

    test "reset_fail_streak clears an accumulated streak (APPROVE path)" do
      {:ok, pid} = Session.start_link(1)
      for t <- 1..7, do: Session.advance_progress(pid, obs("same", true, 0, t), settings())
      assert %{fail_streak: 4} = Session.progress_stats(pid)

      assert :ok = Session.reset_fail_streak(pid)
      assert %{fail_streak: 0} = Session.progress_stats(pid)
    end

    test "claim_capped_comment returns true exactly once" do
      {:ok, pid} = Session.start_link(1)
      assert Session.claim_capped_comment(pid) == true
      assert Session.claim_capped_comment(pid) == false
      assert Session.claim_capped_comment(pid) == false
    end
  end
end
