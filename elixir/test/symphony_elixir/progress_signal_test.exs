defmodule SymphonyElixir.ProgressSignalTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ProgressSignal

  @config %{window_k: 4, trigger_min_turns: 4}

  # Drive a sequence of per-turn inputs through advance/2, returning the final
  # rolled-forward state. `turn_count` auto-increments unless overridden.
  defp run(inputs) do
    inputs
    |> Enum.with_index(1)
    |> Enum.reduce(ProgressSignal.new(), fn {input, turn}, state ->
      ProgressSignal.advance(state, Map.put_new(input, :turn_count, turn))
    end)
  end

  defp dirty(hash, commits \\ 0),
    do: %{hash: hash, empty: false, commits_since: commits, error_sig: nil}

  defp empty(hash, commits \\ 0),
    do: %{hash: hash, empty: true, commits_since: commits, error_sig: nil}

  describe "assess/2 status classification" do
    test "distinct dirty edits each turn are progressing" do
      state = run(for n <- 1..6, do: dirty("h#{n}"))
      assert ProgressSignal.assess(state, @config).status == :progressing
    end

    test "identical DIRTY tree for K turns stays progressing (empty-tree guard)" do
      state = run(for _ <- 1..6, do: dirty("same"))
      assessment = ProgressSignal.assess(state, @config)
      assert assessment.status == :progressing
      assert assessment.evidence.tree_hash_streak == 6
    end

    test "identical EMPTY tree for K turns is stuck_state" do
      state = run(for _ <- 1..4, do: empty("empty"))
      assert ProgressSignal.assess(state, @config).status == :stuck_state
    end

    test "empty tree below K turns is not yet stuck" do
      state = run(for _ <- 1..3, do: empty("empty"))
      assert ProgressSignal.assess(state, @config).status == :progressing
    end

    test "A,B,A,B working-tree flip-flop is oscillating" do
      state = run([dirty("A"), dirty("B"), dirty("A"), dirty("B")])
      assert ProgressSignal.assess(state, @config).status == :oscillating
    end

    test "A,B,A,C is not oscillating" do
      state = run([dirty("A"), dirty("B"), dirty("A"), dirty("C")])
      assert ProgressSignal.assess(state, @config).status == :progressing
    end

    test "repeated error signature >= K turns is repeated_error" do
      input = %{hash: "h", empty: false, commits_since: 0, error_sig: {:codex, :port_exit}}
      state = run(for _ <- 1..4, do: input)
      assert ProgressSignal.assess(state, @config).status == :repeated_error
    end

    test "a single error then a clean turn resets the error streak" do
      state =
        run([
          %{hash: "h1", empty: false, commits_since: 0, error_sig: {:codex, :port_exit}},
          dirty("h2")
        ])

      assert state.error_sig == nil
      assert ProgressSignal.assess(state, @config).evidence.error_sig == nil
    end

    test "oscillation takes precedence over repeated_error" do
      err = {:codex, :port_exit}

      state =
        run([
          %{hash: "A", empty: false, commits_since: 0, error_sig: err},
          %{hash: "B", empty: false, commits_since: 0, error_sig: err},
          %{hash: "A", empty: false, commits_since: 0, error_sig: err},
          %{hash: "B", empty: false, commits_since: 0, error_sig: err}
        ])

      assert ProgressSignal.assess(state, @config).status == :oscillating
    end
  end

  describe "at_risk_no_commits flag (independent of status)" do
    test "fires once turn_count reaches K with zero commits" do
      below = run(for n <- 1..3, do: dirty("h#{n}"))
      refute ProgressSignal.assess(below, @config).at_risk_no_commits

      at = run(for n <- 1..4, do: dirty("h#{n}"))
      assert ProgressSignal.assess(at, @config).at_risk_no_commits
    end

    test "does not fire once a commit lands" do
      state = run(for n <- 1..5, do: dirty("h#{n}", 1))
      assessment = ProgressSignal.assess(state, @config)
      refute assessment.at_risk_no_commits
    end

    test "coexists with :progressing on a dirty tree" do
      state = run(for n <- 1..5, do: dirty("h#{n}"))
      assessment = ProgressSignal.assess(state, @config)
      assert assessment.status == :progressing
      assert assessment.at_risk_no_commits
    end
  end

  describe "trigger?/2" do
    test "true for any non-progressing status" do
      stuck = run(for _ <- 1..4, do: empty("e"))
      assert ProgressSignal.trigger?(ProgressSignal.assess(stuck, @config), @config)
    end

    test "true via at_risk arm once min_turns is cleared" do
      state = run(for n <- 1..4, do: dirty("h#{n}"))
      assessment = ProgressSignal.assess(state, @config)
      assert assessment.status == :progressing
      assert ProgressSignal.trigger?(assessment, @config)
    end

    test "false while progressing, committing, and below min_turns" do
      state = run(for n <- 1..2, do: dirty("h#{n}", 1))
      refute ProgressSignal.trigger?(ProgressSignal.assess(state, @config), @config)
    end
  end

  describe "IDE-189 replay regression" do
    # 20 turns, tree dirty every turn, 0 commits, no error signature. The
    # motivating incident: progressing-but-0-commits, which must NOT be stuck.
    test "realistic: a distinct edit each turn => progressing + at_risk from turn 4" do
      per_turn =
        Enum.map(1..20, fn n ->
          %{hash: "edit-#{n}", empty: false, commits_since: 0, error_sig: nil, turn_count: n}
        end)

      assert_replay(per_turn)
    end

    test "adversarial: final tree reached turn 6 then 14 identical dirty turns => still progressing" do
      per_turn =
        Enum.map(1..20, fn n ->
          hash = if n <= 6, do: "edit-#{n}", else: "final"
          %{hash: hash, empty: false, commits_since: 0, error_sig: nil, turn_count: n}
        end)

      assert_replay(per_turn)
    end

    defp assert_replay(per_turn) do
      Enum.reduce(per_turn, ProgressSignal.new(), fn input, state ->
        state = ProgressSignal.advance(state, input)
        assessment = ProgressSignal.assess(state, @config)

        assert assessment.status == :progressing,
               "turn #{input.turn_count}: expected :progressing, got #{assessment.status}"

        if input.turn_count >= 4 do
          assert assessment.at_risk_no_commits, "turn #{input.turn_count}: expected at_risk"
          assert ProgressSignal.trigger?(assessment, @config), "turn #{input.turn_count}: expected trigger"
        end

        state
      end)
    end
  end
end
