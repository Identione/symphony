defmodule SymphonyElixir.ProgressSignalTest do
  @moduledoc """
  Pure (no-IO) classifier coverage for IDE-211 Layer 1 progress signals,
  including a direct replay of the IDE-189 incident corpus (§0 of the plan):
  20 dirty turns producing 0 commits must stay `:progressing` while flagging
  `at_risk_no_commits`, and `trigger?/2` must fire from turn K via that flag —
  never via `:stuck_state` (the tree is dirty).
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.ProgressSignal

  # K=4 default; build a settings struct with explicit progress knobs so the
  # truth table doesn't depend on the shipped WORKFLOW.md fixture's values.
  defp settings(overrides \\ %{}) do
    base = Config.settings!()

    agent =
      base.agent
      |> Map.merge(%{
        progress_signal_enabled: true,
        progress_signal_window_k: 4,
        progress_signal_git_timeout_ms: 2_000,
        progress_trigger_min_turns: 4
      })
      |> Map.merge(overrides)

    %{base | agent: agent}
  end

  # Drive a sequence of per-turn observations through `advance/3`, returning the
  # final state. `obs_for` builds each observation from a {hash, empty,
  # commits_since, error_sig} tuple, stamping a 1-based turn_count.
  defp run(seq, settings) do
    seq
    |> Enum.with_index(1)
    |> Enum.reduce(ProgressSignal.initial(), fn {{hash, empty, commits, sig}, turn}, state ->
      ProgressSignal.advance(
        state,
        %{hash: hash, empty: empty, commits_since: commits, error_sig: sig, turn_count: turn},
        settings
      )
    end)
  end

  describe "classifier truth table" do
    test "distinct dirty edits each turn with commits stay :progressing" do
      seq = for t <- 1..6, do: {"h#{t}", false, t, nil}
      state = run(seq, settings())

      assert state.assessment.status == :progressing
      refute state.assessment.at_risk_no_commits
    end

    test ":stuck_state only fires on an empty (clean) tree held for >= K turns" do
      # K=4 identical hashes, clean tree, no commits.
      clean = run(List.duplicate({"same", true, 0, nil}, 4), settings())
      assert clean.assessment.status == :stuck_state

      # 3 identical clean turns is below K — not yet stuck.
      below = run(List.duplicate({"same", true, 0, nil}, 3), settings())
      assert below.assessment.status == :progressing
    end

    test "identical *dirty* tree for >= K turns is :progressing, not :stuck (empty-tree guard)" do
      state = run(List.duplicate({"same", false, 0, nil}, 6), settings())

      assert state.assessment.status == :progressing
      assert state.assessment.at_risk_no_commits
    end

    test ":oscillating on an A,B,A,B flip-flop over the last 4 turns" do
      state = run([{"a", false, 0, nil}, {"b", false, 0, nil}, {"a", false, 0, nil}, {"b", false, 0, nil}], settings())
      assert state.assessment.status == :oscillating
    end

    test ":oscillating on a period-3 cycle A,B,C,A,B,C (IDE-230 revisit detection)" do
      # A naive period-2 rule sees only distinct consecutive hashes here and
      # misses the cycle. Revisit detection flags the turn the prior state
      # reappears from earlier in the window.
      seq =
        for {h, t} <- Enum.with_index(~w(a b c a b c), 1), do: {h, false, t, nil}

      state = run(seq, settings(%{progress_signal_revisit_window: 10}))
      assert state.assessment.status == :oscillating
    end

    test "an identical *immediately-previous* hash stays in the :stuck domain, not :oscillating" do
      # current == prev is the stuck/held-tree domain; revisit detection
      # explicitly excludes it so a held tree isn't misread as a cycle.
      seq = [{"a", false, 1, nil}, {"b", false, 1, nil}, {"b", false, 1, nil}]
      state = run(seq, settings(%{progress_signal_revisit_window: 10}))
      refute state.assessment.status == :oscillating
    end

    test "a revisit older than the bounded window is not flagged" do
      # window=2 only retains [current, prev]; the earlier "a" has fallen out so
      # the returning "a" can't be detected as a revisit.
      seq = [{"a", false, 1, nil}, {"b", false, 1, nil}, {"c", false, 1, nil}, {"a", false, 1, nil}]
      state = run(seq, settings(%{progress_signal_revisit_window: 2}))
      refute state.assessment.status == :oscillating
    end

    test ":repeated_error once the same signature streaks to K" do
      seq = List.duplicate({"h", false, 1, {:claude, :invalid_request}}, 4)
      state = run(seq, settings())
      assert state.assessment.status == :repeated_error
    end

    test "a clean turn between errors breaks the error streak" do
      seq = [
        {"h1", false, 1, {:claude, :invalid_request}},
        {"h2", false, 1, {:claude, :invalid_request}},
        # no terminal error this turn — streak resets
        {"h3", false, 1, nil},
        {"h4", false, 1, {:claude, :invalid_request}}
      ]

      state = run(seq, settings())
      assert state.assessment.status == :progressing
      assert state.assessment.evidence.error_sig_streak == 1
    end

    test "at_risk_no_commits gates on turn_count >= K" do
      below = run(for(t <- 1..3, do: {"h#{t}", false, 0, nil}), settings())
      refute below.assessment.at_risk_no_commits

      at_k = run(for(t <- 1..4, do: {"h#{t}", false, 0, nil}), settings())
      assert at_k.assessment.at_risk_no_commits
    end

    test "a single commit clears at_risk_no_commits" do
      state = run(for(t <- 1..5, do: {"h#{t}", false, 1, nil}), settings())
      refute state.assessment.at_risk_no_commits
    end
  end

  describe "trigger?/2" do
    test "false on a healthy progressing session with commits" do
      state = run(for(t <- 1..5, do: {"h#{t}", false, t, nil}), settings())
      refute ProgressSignal.trigger?(state.assessment, settings())
    end

    test "true via the at_risk_no_commits arm even while :progressing" do
      state = run(for(t <- 1..4, do: {"h#{t}", false, 0, nil}), settings())
      assert state.assessment.status == :progressing
      assert ProgressSignal.trigger?(state.assessment, settings())
    end

    test "true on a severe status regardless of commits" do
      state = run(List.duplicate({"same", true, 1, nil}, 4), settings())
      assert state.assessment.status == :stuck_state
      assert ProgressSignal.trigger?(state.assessment, settings())
    end
  end

  describe "IDE-189 regression" do
    # The motivating incident: 20 turns, dirty tree throughout, 0 commits, no
    # terminal error. Both the realistic (distinct edit each turn) and the
    # adversarial (final tree reached early, then identical-dirty) shapes must
    # land on :progressing + at_risk_no_commits for all turns, and trigger?/2
    # must be true from turn 4 (K) onward.
    test "realistic: distinct dirty edit each turn, 0 commits" do
      assert_ide189(fn t -> {"turn-#{t}", false, 0, nil} end)
    end

    test "adversarial: final tree reached at turn 6, then 14 identical dirty turns" do
      assert_ide189(fn t ->
        hash = if t <= 6, do: "turn-#{t}", else: "final"
        {hash, false, 0, nil}
      end)
    end

    defp assert_ide189(obs_fun) do
      settings = settings()

      Enum.reduce(1..20, ProgressSignal.initial(), fn t, state ->
        {hash, empty, commits, sig} = obs_fun.(t)

        next =
          ProgressSignal.advance(
            state,
            %{hash: hash, empty: empty, commits_since: commits, error_sig: sig, turn_count: t},
            settings
          )

        assert next.assessment.status == :progressing,
               "turn #{t} expected :progressing, got #{inspect(next.assessment.status)}"

        if t >= 4 do
          assert next.assessment.at_risk_no_commits, "turn #{t} should be at risk"
          assert ProgressSignal.trigger?(next.assessment, settings), "turn #{t} should trigger"
        end

        next
      end)
    end
  end
end
