defmodule SymphonyElixir.OverseerTest do
  @moduledoc """
  Pure-decision coverage for the Layer 2 overseer (IDE-212 / IDE-230): the
  streak/cadence trigger (with cooldown + per-session cap), verdict
  parsing/validation, the verdict→action map (confidence floor,
  nudge-iff-steering invariant, abort gate, give-up findings), and the `run/3`
  engine seam (fail-open on a malformed/error engine response).
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema.Overseer, as: OverseerConfig
  alias SymphonyElixir.Overseer

  defp config(overrides \\ %{}) do
    struct(%OverseerConfig{}, overrides)
  end

  defp ctx(overrides) do
    Map.merge(%{turn: 7, calls: 0, last_call_turn: nil, fail_streak: 0}, overrides)
  end

  defp verdict(overrides \\ %{}) do
    base = %{
      verdict: :converging,
      confidence: 0.9,
      recommended_action: :continue,
      steering_message: nil,
      findings: nil,
      rationale: "looks fine"
    }

    Map.merge(base, overrides)
  end

  describe "triggered?/3" do
    test "fires when the fail-streak reaches streak_to_llm" do
      assert Overseer.triggered?(7, 5, config(%{streak_to_llm: 5}))
      refute Overseer.triggered?(7, 4, config(%{streak_to_llm: 5}))
    end

    test "fires on the mandatory cadence regardless of streak" do
      assert Overseer.triggered?(40, 0, config(%{mandatory_llm_every: 40}))
      refute Overseer.triggered?(41, 0, config(%{mandatory_llm_every: 40}))
    end

    test "mandatory_llm_every: 0 disables the periodic arm" do
      refute Overseer.triggered?(0, 0, config(%{mandatory_llm_every: 0, streak_to_llm: 5}))
    end
  end

  describe "should_run?/2" do
    test "fires via the fail-streak within the cooldown/cap window" do
      assert Overseer.should_run?(ctx(%{turn: 7, fail_streak: 5}), config(%{streak_to_llm: 5}))
    end

    test "fires via the mandatory cadence" do
      assert Overseer.should_run?(ctx(%{turn: 40, fail_streak: 0}), config(%{mandatory_llm_every: 40}))
    end

    test "does not fire when neither trigger is met" do
      refute Overseer.should_run?(ctx(%{turn: 7, fail_streak: 2}), config(%{streak_to_llm: 5, mandatory_llm_every: 40}))
    end

    test "does not fire once the per-session cap is reached" do
      refute Overseer.should_run?(ctx(%{turn: 7, fail_streak: 5, calls: 2}), config(%{max_calls_per_session: 2}))
    end

    test "respects the cooldown (min_turns_between)" do
      refute Overseer.should_run?(
               ctx(%{turn: 17, fail_streak: 5, last_call_turn: 16}),
               config(%{min_turns_between: 3})
             )

      assert Overseer.should_run?(
               ctx(%{turn: 19, fail_streak: 5, last_call_turn: 16}),
               config(%{min_turns_between: 3})
             )
    end

    test "never fires for an unsupported engine" do
      refute Overseer.should_run?(ctx(%{turn: 40}), config(%{engine: "sidecar"}))
    end
  end

  describe "parse/1" do
    test "atomizes a well-formed verdict" do
      raw = %{
        "verdict" => "thrashing",
        "confidence" => 0.8,
        "recommended_action" => "escalate",
        "steering_message" => nil,
        "rationale" => "same error 5x"
      }

      assert {:ok, parsed} = Overseer.parse(raw)
      assert parsed.verdict == :thrashing
      assert parsed.recommended_action == :escalate
      assert parsed.confidence == 0.8
      assert parsed.steering_message == nil
    end

    test "rejects unknown enum values" do
      raw = %{
        "verdict" => "exploding",
        "confidence" => 0.8,
        "recommended_action" => "escalate",
        "steering_message" => nil,
        "rationale" => "x"
      }

      assert {:error, {:overseer_bad_enum, "verdict", "exploding"}} = Overseer.parse(raw)
    end

    test "rejects a missing required field" do
      raw = %{
        "verdict" => "converging",
        "confidence" => 0.8,
        "recommended_action" => "continue",
        "steering_message" => nil
      }

      assert {:error, {:overseer_missing_field, "rationale"}} = Overseer.parse(raw)
    end

    test "accepts a string steering_message" do
      raw = %{
        "verdict" => "converging",
        "confidence" => 0.7,
        "recommended_action" => "nudge",
        "steering_message" => "commit and push",
        "rationale" => "work is done but uncommitted"
      }

      assert {:ok, %{steering_message: "commit and push", findings: nil}} = Overseer.parse(raw)
    end

    test "parses structured findings (and tolerates absent/null)" do
      findings = %{"summary" => "stuck", "blockers" => ["x"], "next_steps_for_human" => ["y"]}

      with_findings = %{
        "verdict" => "thrashing",
        "confidence" => 0.8,
        "recommended_action" => "escalate",
        "steering_message" => nil,
        "findings" => findings,
        "rationale" => "no progress"
      }

      assert {:ok, %{findings: ^findings}} = Overseer.parse(with_findings)

      assert {:ok, %{findings: nil}} =
               Overseer.parse(%{with_findings | "findings" => nil})

      assert {:error, {:overseer_bad_field, "findings"}} =
               Overseer.parse(%{with_findings | "findings" => "not-an-object"})
    end

    test "rejects a non-map" do
      assert {:error, :overseer_verdict_not_a_map} = Overseer.parse("nope")
    end
  end

  describe "decide_action/2" do
    test "downgrades below the confidence floor" do
      assert {:continue, :low_confidence} =
               Overseer.decide_action(
                 verdict(%{confidence: 0.3, recommended_action: :escalate}),
                 config(%{confidence_floor: 0.6})
               )
    end

    test "passes a healthy continue through" do
      assert {:continue, :ok} = Overseer.decide_action(verdict(), config())
    end

    test "nudge requires a non-empty steering_message" do
      assert {:nudge, "commit now"} =
               Overseer.decide_action(
                 verdict(%{recommended_action: :nudge, steering_message: "commit now"}),
                 config()
               )

      assert {:continue, :missing_steering} =
               Overseer.decide_action(
                 verdict(%{recommended_action: :nudge, steering_message: nil}),
                 config()
               )
    end

    test "budget extension carries the rationale" do
      assert {:recommend_extend_budget, "needs more turns"} =
               Overseer.decide_action(
                 verdict(%{recommended_action: :recommend_extend_budget, rationale: "needs more turns"}),
                 config()
               )
    end

    test "escalate carries the rationale and findings" do
      findings = %{"summary" => "stuck", "blockers" => ["missing secret"]}

      assert {:escalate, "human please", ^findings} =
               Overseer.decide_action(
                 verdict(%{recommended_action: :escalate, rationale: "human please", findings: findings}),
                 config()
               )
    end

    test "abort downgrades to escalate unless allow_abort (carrying findings)" do
      findings = %{"summary" => "wasted"}
      v = verdict(%{recommended_action: :abort, rationale: "wasted spend", findings: findings})

      assert {:escalate, "wasted spend", ^findings} = Overseer.decide_action(v, config(%{allow_abort: false}))
      assert {:abort, "wasted spend", ^findings} = Overseer.decide_action(v, config(%{allow_abort: true}))
    end
  end

  describe "run/3" do
    test "parses a verdict from the injected engine" do
      engine = fn _messages, _config ->
        {:ok,
         %{
           "verdict" => "converging",
           "confidence" => 0.9,
           "recommended_action" => "continue",
           "steering_message" => nil,
           "rationale" => "ok"
         }}
      end

      assert {:ok, %{verdict: :converging}} = Overseer.run(%{}, config(), engine: engine)
    end

    test "propagates an engine error (fail-open at the call site)" do
      engine = fn _messages, _config -> {:error, :boom} end
      assert {:error, :boom} = Overseer.run(%{}, config(), engine: engine)
    end

    test "rejects a malformed verdict from the engine" do
      engine = fn _messages, _config -> {:ok, %{"verdict" => "converging"}} end
      assert {:error, {:overseer_missing_field, _}} = Overseer.run(%{}, config(), engine: engine)
    end

    test "refuses an unsupported engine without calling out" do
      assert {:error, {:engine_unsupported, "sidecar"}} =
               Overseer.run(%{}, config(%{engine: "sidecar"}), engine: fn _, _ -> flunk("called") end)
    end
  end
end
