defmodule SymphonyElixir.Overseer.SessionTest do
  @moduledoc """
  Run-scoped overseer state (IDE-212 / IDE-230): the bounded transcript ring
  buffer, the call bookkeeping (`calls` / `last_call_turn`) that backs the
  cooldown + cap, and the worker-side progress / fail-streak state.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Overseer.Session

  defp env(n), do: %{event: :assistant_message, payload: %{text: "m#{n}"}}

  defp observation(hash, turn, opts \\ []) do
    %{
      hash: hash,
      empty: Keyword.get(opts, :empty, false),
      commits_since: Keyword.get(opts, :commits_since, 1),
      error_sig: nil,
      turn_count: turn
    }
  end

  # K=4 default; progressing turns keep the streak at 0, a cycle (revisit) trips
  # trigger?/2 and accumulates the streak.
  defp settings do
    base = Config.settings!()
    %{base | agent: Map.merge(base.agent, %{progress_signal_window_k: 4, progress_trigger_min_turns: 4})}
  end

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

  describe "worker-side progress / fail-streak (IDE-230)" do
    test "fresh-tree progressing turns keep the fail-streak at 0" do
      {:ok, pid} = Session.start_link(0)

      for t <- 1..5 do
        %{fail_streak: streak} = Session.advance_progress(pid, observation("h#{t}", t), settings())
        assert streak == 0
      end

      assert %{fail_streak: 0, assessment: %{status: :progressing}} = Session.progress_snapshot(pid)
    end

    test "a sustained cycle accumulates the fail-streak; reset clears it" do
      {:ok, pid} = Session.start_link(0)
      seq = [{"a", 1}, {"b", 2}, {"a", 3}, {"b", 4}, {"a", 5}]

      streaks =
        for {hash, turn} <- seq do
          Session.advance_progress(pid, observation(hash, turn), settings()).fail_streak
        end

      # The flip-flop (A,B,A,…) is detected and the streak climbs.
      assert List.last(streaks) >= 1
      assert %{status: :oscillating} = Session.progress_snapshot(pid).assessment

      Session.reset_fail_streak(pid)
      assert %{fail_streak: 0} = Session.progress_snapshot(pid)
    end

    test "dispatch_head is captured once and the cap-comment claim is one-shot" do
      {:ok, pid} = Session.start_link(0)

      assert Session.dispatch_head(pid) == nil
      Session.put_dispatch_head(pid, "abc123")
      assert Session.dispatch_head(pid) == "abc123"
      # Subsequent captures are ignored.
      Session.put_dispatch_head(pid, "def456")
      assert Session.dispatch_head(pid) == "abc123"

      assert Session.claim_capped_comment(pid) == true
      assert Session.claim_capped_comment(pid) == false
    end
  end
end
