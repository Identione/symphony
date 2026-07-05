defmodule SymphonyElixir.OrchestratorRetryPolicyTest do
  @moduledoc """
  Covers the IDE-72 per-failure-code retry policy. Splits the proof into

    1. pure decisions from `Orchestrator.RetryPolicy.decide/4` (the policy
       table itself), and
    2. orchestrator integration through `handle_info({:DOWN, …})` so the
       error code (read from the `{:agent_run_failed, code, reason}` exit
       reason) and override delays are observable in the live
       retry_attempts/blocked maps.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.Orchestrator.RetryPolicy

  defp start_orchestrator!(suffix) do
    name = Module.concat(__MODULE__, suffix)
    {:ok, pid} = Orchestrator.start_link(name: name)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  defp seed_running_entry!(pid, issue_id, identifier, opts \\ []) do
    ref = make_ref()
    # `retry_attempt: 0` (or unset) seeds the running entry as a first-attempt
    # worker; `next_retry_attempt_from_running/1` returns nil and the policy
    # treats this as attempt #1.
    retry_attempt = Keyword.get(opts, :retry_attempt, 0)

    running_entry = %{
      pid: self(),
      ref: ref,
      identifier: identifier,
      retry_attempt: retry_attempt,
      issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress"},
      started_at: DateTime.utc_now()
    }

    initial_state = :sys.get_state(pid)

    :sys.replace_state(pid, fn _ ->
      initial_state
      |> Map.put(:running, %{issue_id => running_entry})
      |> Map.put(:claimed, MapSet.put(initial_state.claimed, issue_id))
      |> Map.put(:retry_attempts, %{})
      |> Map.put(:blocked, %{})
    end)

    ref
  end

  # Synthesises the exit reason `AgentRunner.run/3` would raise for a
  # classified upstream failure. Wrapping in `{:agent_run_failed, code, inner}`
  # is the contract `Orchestrator.extract_error_code/1` reads in the :DOWN
  # handler — same wrapper IDE-71/IDE-73 standardised on.
  defp agent_run_failed_reason(code, inner \\ nil) do
    {:agent_run_failed, code, inner}
  end

  describe "RetryPolicy.decide/4 — built-in policy table" do
    test "rate_limited uses long backoff and honors Retry-After hint" do
      settings = nil

      assert {:retry, 30_000} = RetryPolicy.decide(:rate_limited, 1, nil, settings)
      assert {:retry, 60_000} = RetryPolicy.decide(:rate_limited, 2, nil, settings)
      assert {:retry, 45_000} = RetryPolicy.decide(:rate_limited, 1, 45_000, settings)

      # A subscription usage-limit reset can be hours out — `:rate_limited`
      # honors the embedded `retry-after` up to a 6h ceiling rather than the
      # shared 15-min cap, so it doesn't re-hit the wall mid-window.
      assert {:retry, 5_000_000} = RetryPolicy.decide(:rate_limited, 1, 5_000_000, settings)
      assert {:retry, 21_600_000} = RetryPolicy.decide(:rate_limited, 1, 99_000_000, settings)
    end

    test "overloaded honors Retry-After but stays on the short cap (transient 503)" do
      assert {:retry, 30_000} = RetryPolicy.decide(:overloaded, 1, nil, nil)
      assert {:retry, 12_000} = RetryPolicy.decide(:overloaded, 1, 12_000, nil)
      # A malformed multi-hour hint must not strand a transient 503 — clamped to
      # the 15-min baseline, unlike `:rate_limited`.
      assert {:retry, 900_000} = RetryPolicy.decide(:overloaded, 1, 5_000_000, nil)
    end

    test "context_window_exhausted, quota_exceeded, invalid_request, budget_exhausted, overseer_escalation never retry" do
      for code <- [
            :context_window_exhausted,
            :quota_exceeded,
            :invalid_request,
            :budget_exhausted,
            :overseer_escalation
          ] do
        assert RetryPolicy.decide(code, 1, nil, nil) == :no_retry, "code=#{code}"
        assert RetryPolicy.decide(code, 7, 60_000, nil) == :no_retry, "code=#{code} retry_after"
      end
    end

    test "unknown code falls back to the historical exponential backoff" do
      # attempt=1 → base 10_000, attempt=2 → 20_000, … capped at max_retry_backoff_ms
      assert {:retry, 10_000} = RetryPolicy.decide(:unknown, 1, nil, nil)
      assert {:retry, 20_000} = RetryPolicy.decide(:unknown, 2, nil, nil)
      assert {:retry, 40_000} = RetryPolicy.decide(:unknown, 3, nil, nil)
      # Default cap is 300_000ms; attempt 6 would compute 10_000 * 2^5 = 320_000.
      assert {:retry, 300_000} = RetryPolicy.decide(:unknown, 6, nil, nil)
    end

    test "max_turns_reached uses a 1s constant cadence matching the :normal continuation re-poll (IDE-74)" do
      # Constant 1s so the attempt counter has no effect, and the cadence
      # matches the existing `delay_type: :continuation` re-poll for clean
      # `:normal` exits.
      assert {:retry, 1_000} = RetryPolicy.decide(:max_turns_reached, 1, nil, nil)
      assert {:retry, 1_000} = RetryPolicy.decide(:max_turns_reached, 7, nil, nil)
      # A `Retry-After` hint is meaningless for an orchestrator-side cap.
      assert {:retry, 1_000} = RetryPolicy.decide(:max_turns_reached, 1, 30_000, nil)
    end

    test "an unrecognized error code is treated as :unknown" do
      assert RetryPolicy.decide(:_does_not_exist, 1, nil, nil) ==
               RetryPolicy.decide(:unknown, 1, nil, nil)
    end

    test "max_sessions_per_issue is recognized and never retries" do
      assert :max_sessions_per_issue in RetryPolicy.recognized_codes()
      assert RetryPolicy.decide(:max_sessions_per_issue, 1, nil, nil) == :no_retry
      assert RetryPolicy.decide(:max_sessions_per_issue, 7, 60_000, nil) == :no_retry
    end

    test "Retry-After is ignored for codes that do not opt in" do
      # `:unknown` does not honor_retry_after by default
      assert {:retry, 10_000} = RetryPolicy.decide(:unknown, 1, 999_000, nil)
    end
  end

  describe "RetryPolicy.decide/4 — config overrides" do
    test "operator can override a built-in backoff entry" do
      settings = %{
        agent: %{
          max_retry_backoff_ms: 600_000,
          retry_policy: %{
            "rate_limited" => %{
              "strategy" => "backoff",
              "base_ms" => 120_000,
              "max_ms" => 600_000,
              "honor_retry_after" => false
            }
          }
        }
      }

      assert {:retry, 120_000} = RetryPolicy.decide(:rate_limited, 1, nil, settings)
      # honor_retry_after disabled → hint is ignored
      assert {:retry, 120_000} = RetryPolicy.decide(:rate_limited, 1, 5_000, settings)
      assert {:retry, 240_000} = RetryPolicy.decide(:rate_limited, 2, nil, settings)
    end

    test "operator can flip a default-retried code to :no_retry" do
      settings = %{
        agent: %{
          max_retry_backoff_ms: 300_000,
          retry_policy: %{"unknown" => %{"strategy" => "no_retry"}}
        }
      }

      assert RetryPolicy.decide(:unknown, 1, nil, settings) == :no_retry
    end

    test "operator can opt a :no_retry code back into backoff" do
      settings = %{
        agent: %{
          max_retry_backoff_ms: 300_000,
          retry_policy: %{
            "context_window_exhausted" => %{
              "strategy" => "backoff",
              "base_ms" => 5_000,
              "max_ms" => 60_000
            }
          }
        }
      }

      assert {:retry, 5_000} =
               RetryPolicy.decide(:context_window_exhausted, 1, nil, settings)
    end

    test "honor_retry_after override on the unknown bucket honors hints" do
      settings = %{
        agent: %{
          max_retry_backoff_ms: 300_000,
          retry_policy: %{
            "unknown" => %{"honor_retry_after" => true, "max_ms" => 300_000}
          }
        }
      }

      assert {:retry, 7_000} = RetryPolicy.decide(:unknown, 1, 7_000, settings)
    end
  end

  describe "AgentRunner.classify_error_code/1 + extract_retry_after_ms/1" do
    test "classifies Claude SDK error tuples and parses Retry-After hint" do
      reason = {:claude_sdk_error, :rate_limited, "RateLimitError: rate_limited (retry-after: 30s)"}
      assert :rate_limited = AgentRunner.classify_error_code(reason)
      assert 30_000 = AgentRunner.extract_retry_after_ms(reason)

      reason2 = {:claude_sdk_error, :context_window_exhausted, "prompt is too long"}
      assert :context_window_exhausted = AgentRunner.classify_error_code(reason2)
      assert is_nil(AgentRunner.extract_retry_after_ms(reason2))
    end

    test "classifies Codex turn/failed tuples and parses upstream Retry-After header / retry_after field" do
      params = %{
        "error" => %{"code" => "rate_limit", "status" => 429, "headers" => %{"Retry-After" => "45"}}
      }

      reason = {:turn_failed, :rate_limited, params}
      assert :rate_limited = AgentRunner.classify_error_code(reason)
      assert 45_000 = AgentRunner.extract_retry_after_ms(reason)

      reason2 =
        {:codex_error_notification, :overloaded, %{"error" => %{"retry_after" => 7, "status" => 503}}}

      assert :overloaded = AgentRunner.classify_error_code(reason2)
      assert 7_000 = AgentRunner.extract_retry_after_ms(reason2)
    end

    test "non-adapter reasons fall back to :unknown with no Retry-After hint" do
      assert :port_exit = AgentRunner.classify_error_code({:port_exit, 137})
      assert is_nil(AgentRunner.extract_retry_after_ms({:port_exit, 137}))

      assert :unknown = AgentRunner.classify_error_code(:some_atom)
      assert is_nil(AgentRunner.extract_retry_after_ms(:some_atom))
    end
  end

  describe "orchestrator :DOWN policy integration" do
    test "rate_limited DOWN schedules a long-backoff retry honoring Retry-After" do
      pid = start_orchestrator!(:RateLimitedDownOrchestrator)
      issue_id = "ide-72-rate-limited"
      ref = seed_running_entry!(pid, issue_id, "IDE-72-RL")

      # Inner reason carries the upstream `Retry-After` header so the
      # orchestrator's reason-extraction path discovers the hint without
      # any sidechannel message.
      inner =
        {:turn_failed, :rate_limited, %{"error" => %{"headers" => %{"Retry-After" => "45"}, "status" => 429}}}

      baseline_ms = System.monotonic_time(:millisecond)
      send(pid, {:DOWN, ref, :process, self(), agent_run_failed_reason(:rate_limited, inner)})
      Process.sleep(75)
      state = :sys.get_state(pid)

      assert %{attempt: 1, due_at_ms: due_at_ms, error: error} =
               state.retry_attempts[issue_id]

      assert error =~ "rate_limited"
      remaining = due_at_ms - baseline_ms
      assert remaining in 44_000..46_000, "expected ~45s retry-after honored, got #{remaining}"
      refute Map.has_key?(state.blocked, issue_id)
    end

    test "overloaded DOWN without a Retry-After uses the long-backoff default" do
      pid = start_orchestrator!(:OverloadedDownOrchestrator)
      issue_id = "ide-72-overloaded"
      ref = seed_running_entry!(pid, issue_id, "IDE-72-OV")

      baseline_ms = System.monotonic_time(:millisecond)
      send(pid, {:DOWN, ref, :process, self(), agent_run_failed_reason(:overloaded)})
      Process.sleep(75)
      state = :sys.get_state(pid)

      assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
      remaining = due_at_ms - baseline_ms
      assert remaining in 29_000..31_000, "expected ~30s long backoff, got #{remaining}"
    end

    test "context_window_exhausted DOWN moves the issue to blocked without scheduling a retry" do
      pid = start_orchestrator!(:ContextWindowDownOrchestrator)
      issue_id = "ide-72-context"
      ref = seed_running_entry!(pid, issue_id, "IDE-72-CTX")

      send(pid, {:DOWN, ref, :process, self(), agent_run_failed_reason(:context_window_exhausted)})
      Process.sleep(75)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.retry_attempts, issue_id)
      assert %{identifier: "IDE-72-CTX", error: error} = state.blocked[issue_id]
      assert error =~ "context_window_exhausted"
    end

    test "quota_exceeded DOWN moves the issue to blocked without scheduling a retry" do
      pid = start_orchestrator!(:QuotaDownOrchestrator)
      issue_id = "ide-72-quota"
      ref = seed_running_entry!(pid, issue_id, "IDE-72-Q")

      send(pid, {:DOWN, ref, :process, self(), agent_run_failed_reason(:quota_exceeded)})
      Process.sleep(75)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.retry_attempts, issue_id)
      assert %{error: error} = state.blocked[issue_id]
      assert error =~ "quota_exceeded"
    end

    test "max_turns_reached DOWN schedules a 1s continuation-cadence retry (IDE-74)" do
      pid = start_orchestrator!(:MaxTurnsReachedDownOrchestrator)
      issue_id = "ide-74-max-turns"
      ref = seed_running_entry!(pid, issue_id, "IDE-74-MT")

      baseline_ms = System.monotonic_time(:millisecond)

      send(
        pid,
        {:DOWN, ref, :process, self(), agent_run_failed_reason(:max_turns_reached, :max_turns_reached)}
      )

      Process.sleep(75)
      state = :sys.get_state(pid)

      assert %{attempt: 1, due_at_ms: due_at_ms, error: error} =
               state.retry_attempts[issue_id]

      remaining = due_at_ms - baseline_ms
      assert remaining in 800..1_200, "expected ~1s continuation cadence, got #{remaining}"
      assert error =~ "max_turns_reached"
      refute Map.has_key?(state.blocked, issue_id)
    end

    test "missing classification (raw exit) falls back to the historical exponential backoff" do
      pid = start_orchestrator!(:UnknownFallbackOrchestrator)
      issue_id = "ide-72-unknown"
      ref = seed_running_entry!(pid, issue_id, "IDE-72-UN")

      # Raw `:boom` — not an `{:agent_run_failed, …}` wrapper, so the
      # orchestrator extracts no code and the policy falls through to `:unknown`.
      baseline_ms = System.monotonic_time(:millisecond)
      send(pid, {:DOWN, ref, :process, self(), :boom})
      Process.sleep(75)
      state = :sys.get_state(pid)

      assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
      remaining = due_at_ms - baseline_ms
      # First abnormal exit ≈ 10s with the legacy exponential schedule.
      assert remaining in 9_000..11_000, "expected ~10s legacy backoff, got #{remaining}"
    end
  end

  describe "WORKFLOW.md retry_policy config" do
    test "operator override flows from WORKFLOW.md through Config to RetryPolicy" do
      write_workflow_file!(Workflow.workflow_file_path(),
        retry_policy: %{
          rate_limited: %{strategy: "backoff", base_ms: 120_000, max_ms: 600_000},
          unknown: %{strategy: "no_retry"}
        }
      )

      settings = Config.settings!()
      assert is_map(settings.agent.retry_policy)

      assert {:retry, 120_000} = RetryPolicy.decide(:rate_limited, 1, nil, settings)
      assert RetryPolicy.decide(:unknown, 1, nil, settings) == :no_retry
    end

    test "an invalid retry_policy entry surfaces as a workflow validation error" do
      write_workflow_file!(Workflow.workflow_file_path(),
        retry_policy: %{unknown_code_not_in_taxonomy: %{strategy: "backoff"}}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "retry_policy"
    end

    test "an invalid strategy is rejected" do
      write_workflow_file!(Workflow.workflow_file_path(),
        retry_policy: %{rate_limited: %{strategy: "explode"}}
      )

      assert {:error, {:invalid_workflow_config, message}} = Config.validate!()
      assert message =~ "retry_policy"
    end
  end
end
