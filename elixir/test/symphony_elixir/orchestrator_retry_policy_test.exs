defmodule SymphonyElixir.OrchestratorRetryPolicyTest do
  @moduledoc """
  Covers the IDE-72 per-failure-code retry policy. Splits the proof into

    1. pure decisions from `Orchestrator.RetryPolicy.decide/4` (the policy
       table itself), and
    2. orchestrator integration through `handle_info({:DOWN, …})` so the
       cached classification, blocking transition, and override delays are
       observable in the live retry_attempts/blocked maps.
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
    classification = Keyword.get(opts, :classification)
    # `retry_attempt: 0` (or unset) seeds the running entry as a first-attempt
    # worker; `next_retry_attempt_from_running/1` returns nil and the policy
    # treats this as attempt #1.
    retry_attempt = Keyword.get(opts, :retry_attempt, 0)

    running_entry =
      %{
        pid: self(),
        ref: ref,
        identifier: identifier,
        retry_attempt: retry_attempt,
        issue: %Issue{id: issue_id, identifier: identifier, state: "In Progress"},
        started_at: DateTime.utc_now()
      }
      |> maybe_put_classification(classification)

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

  defp maybe_put_classification(entry, nil), do: entry
  defp maybe_put_classification(entry, %{} = c), do: Map.put(entry, :last_failure_classification, c)

  describe "RetryPolicy.decide/4 — built-in policy table" do
    test "rate_limited uses long backoff and honors Retry-After hint" do
      settings = nil

      assert {:retry, 30_000} = RetryPolicy.decide(:rate_limited, 1, nil, settings)
      assert {:retry, 60_000} = RetryPolicy.decide(:rate_limited, 2, nil, settings)
      assert {:retry, 45_000} = RetryPolicy.decide(:rate_limited, 1, 45_000, settings)

      # Hints are clamped to the policy's `max_ms` (default 900_000ms baseline).
      assert {:retry, 900_000} = RetryPolicy.decide(:rate_limited, 1, 5_000_000, settings)
    end

    test "overloaded uses long backoff and honors Retry-After hint" do
      assert {:retry, 30_000} = RetryPolicy.decide(:overloaded, 1, nil, nil)
      assert {:retry, 12_000} = RetryPolicy.decide(:overloaded, 1, 12_000, nil)
    end

    test "context_window_exhausted, quota_exceeded, invalid_request never retry" do
      for code <- [:context_window_exhausted, :quota_exceeded, :invalid_request] do
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

    test "an unrecognized error code is treated as :unknown" do
      assert RetryPolicy.decide(:_does_not_exist, 1, nil, nil) ==
               RetryPolicy.decide(:unknown, 1, nil, nil)
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

  describe "AgentRunner.classify_failure/1" do
    test "extracts code + retry_after from Claude adapter tuples" do
      assert %{error_code: :rate_limited, retry_after_ms: 30_000} =
               AgentRunner.classify_failure({:claude_sdk_error, :rate_limited, "RateLimitError: rate_limited (retry-after: 30s)"})

      assert %{error_code: :context_window_exhausted, retry_after_ms: nil} =
               AgentRunner.classify_failure({:claude_sdk_error, :context_window_exhausted, "prompt is too long"})
    end

    test "extracts code + retry_after from Codex turn/failed tuples" do
      params = %{
        "error" => %{"code" => "rate_limit", "status" => 429, "headers" => %{"Retry-After" => "45"}}
      }

      assert %{error_code: :rate_limited, retry_after_ms: 45_000} =
               AgentRunner.classify_failure({:turn_failed, :rate_limited, params})

      assert %{error_code: :overloaded, retry_after_ms: 7_000} =
               AgentRunner.classify_failure({:codex_error_notification, :overloaded, %{"error" => %{"retry_after" => 7, "status" => 503}}})
    end

    test "unknown reasons fall back to :unknown with no Retry-After" do
      assert %{error_code: :unknown, retry_after_ms: nil} =
               AgentRunner.classify_failure({:port_exit, 137})

      assert %{error_code: :unknown, retry_after_ms: nil} =
               AgentRunner.classify_failure(:some_atom)
    end
  end

  describe "orchestrator :DOWN policy integration" do
    test "rate_limited DOWN schedules a long-backoff retry honoring Retry-After" do
      pid = start_orchestrator!(:RateLimitedDownOrchestrator)
      issue_id = "ide-72-rate-limited"

      ref =
        seed_running_entry!(pid, issue_id, "IDE-72-RL", classification: %{error_code: :rate_limited, retry_after_ms: 45_000})

      baseline_ms = System.monotonic_time(:millisecond)
      send(pid, {:DOWN, ref, :process, self(), :killed})
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

      ref =
        seed_running_entry!(pid, issue_id, "IDE-72-OV", classification: %{error_code: :overloaded, retry_after_ms: nil})

      baseline_ms = System.monotonic_time(:millisecond)
      send(pid, {:DOWN, ref, :process, self(), :killed})
      Process.sleep(75)
      state = :sys.get_state(pid)

      assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
      remaining = due_at_ms - baseline_ms
      assert remaining in 29_000..31_000, "expected ~30s long backoff, got #{remaining}"
    end

    test "context_window_exhausted DOWN moves the issue to blocked without scheduling a retry" do
      pid = start_orchestrator!(:ContextWindowDownOrchestrator)
      issue_id = "ide-72-context"

      ref =
        seed_running_entry!(pid, issue_id, "IDE-72-CTX", classification: %{error_code: :context_window_exhausted, retry_after_ms: nil})

      send(pid, {:DOWN, ref, :process, self(), :killed})
      Process.sleep(75)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.retry_attempts, issue_id)
      assert %{identifier: "IDE-72-CTX", error: error} = state.blocked[issue_id]
      assert error =~ "context_window_exhausted"
    end

    test "quota_exceeded DOWN moves the issue to blocked without scheduling a retry" do
      pid = start_orchestrator!(:QuotaDownOrchestrator)
      issue_id = "ide-72-quota"

      ref =
        seed_running_entry!(pid, issue_id, "IDE-72-Q", classification: %{error_code: :quota_exceeded, retry_after_ms: nil})

      send(pid, {:DOWN, ref, :process, self(), :killed})
      Process.sleep(75)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.retry_attempts, issue_id)
      assert %{error: error} = state.blocked[issue_id]
      assert error =~ "quota_exceeded"
    end

    test "missing classification falls back to the historical exponential backoff" do
      pid = start_orchestrator!(:UnknownFallbackOrchestrator)
      issue_id = "ide-72-unknown"
      ref = seed_running_entry!(pid, issue_id, "IDE-72-UN")

      baseline_ms = System.monotonic_time(:millisecond)
      send(pid, {:DOWN, ref, :process, self(), :boom})
      Process.sleep(75)
      state = :sys.get_state(pid)

      assert %{attempt: 1, due_at_ms: due_at_ms} = state.retry_attempts[issue_id]
      remaining = due_at_ms - baseline_ms
      # First abnormal exit ≈ 10s with the legacy exponential schedule.
      assert remaining in 9_000..11_000, "expected ~10s legacy backoff, got #{remaining}"
    end

    test "`:agent_failure_classified` caches the failure code on the running entry" do
      pid = start_orchestrator!(:ClassificationCacheOrchestrator)
      issue_id = "ide-72-cache"
      ref = seed_running_entry!(pid, issue_id, "IDE-72-C")

      send(
        pid,
        {:agent_failure_classified, issue_id, %{error_code: :quota_exceeded, retry_after_ms: nil, reason_summary: "credit_balance_too_low"}}
      )

      Process.sleep(25)

      send(pid, {:DOWN, ref, :process, self(), :killed})
      Process.sleep(75)
      state = :sys.get_state(pid)

      refute Map.has_key?(state.retry_attempts, issue_id)
      assert %{error: error} = state.blocked[issue_id]
      assert error =~ "quota_exceeded"
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
