defmodule SymphonyElixir.DeterministicFailureTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.DeterministicFailure
  alias SymphonyElixir.Linear.Issue

  defp settings(overrides \\ %{}) do
    base = Config.settings!()

    agent =
      base.agent
      |> Map.merge(%{
        deterministic_failure_alert_threshold: 3,
        deterministic_failure_escalation_threshold: 5,
        deterministic_failure_escalation_state: "Human Review"
      })
      |> Map.merge(overrides)

    %{base | agent: agent}
  end

  describe "decide/3 — pure decision logic" do
    test "first deterministic failure starts a fresh streak with no action" do
      assert {%{code: :quota_exceeded, count: 1, notified_alert?: false, notified_escalation?: false}, :no_action} = DeterministicFailure.decide(nil, :quota_exceeded, settings())
    end

    test "second deterministic failure with the same code increments the streak" do
      first = %{code: :quota_exceeded, count: 1, notified_alert?: false, notified_escalation?: false}

      assert {%{count: 2, notified_alert?: false}, :no_action} =
               DeterministicFailure.decide(first, :quota_exceeded, settings())
    end

    test "hitting the alert threshold returns an :alert action and marks notified_alert?" do
      at_two = %{code: :quota_exceeded, count: 2, notified_alert?: false, notified_escalation?: false}

      assert {%{count: 3, notified_alert?: true, notified_escalation?: false}, {:alert, :quota_exceeded, 3}} =
               DeterministicFailure.decide(at_two, :quota_exceeded, settings())
    end

    test "after alert fires, subsequent failures stay quiet until escalation" do
      after_alert = %{code: :quota_exceeded, count: 3, notified_alert?: true, notified_escalation?: false}

      assert {%{count: 4, notified_alert?: true}, :no_action} =
               DeterministicFailure.decide(after_alert, :quota_exceeded, settings())
    end

    test "hitting the escalation threshold returns an :escalate action and marks both flags" do
      at_four = %{code: :quota_exceeded, count: 4, notified_alert?: true, notified_escalation?: false}

      assert {%{count: 5, notified_escalation?: true, notified_alert?: true}, {:escalate, :quota_exceeded, 5}} =
               DeterministicFailure.decide(at_four, :quota_exceeded, settings())
    end

    test "a transient code resets the counter to :drop" do
      prior = %{code: :quota_exceeded, count: 2, notified_alert?: false, notified_escalation?: false}

      assert {:drop, :no_action} = DeterministicFailure.decide(prior, :rate_limited, settings())
      assert {:drop, :no_action} = DeterministicFailure.decide(prior, :overloaded, settings())
      assert {:drop, :no_action} = DeterministicFailure.decide(prior, :unknown, settings())
    end

    test "a different deterministic code starts a fresh streak at 1" do
      prior = %{code: :quota_exceeded, count: 2, notified_alert?: false, notified_escalation?: false}

      assert {%{code: :context_window_exhausted, count: 1, notified_alert?: false}, :no_action} =
               DeterministicFailure.decide(prior, :context_window_exhausted, settings())
    end

    test "the escalation threshold is hit exactly when count >= M, even with low alert N=1" do
      tight = settings(%{deterministic_failure_alert_threshold: 1, deterministic_failure_escalation_threshold: 2})

      assert {entry, {:alert, :quota_exceeded, 1}} =
               DeterministicFailure.decide(nil, :quota_exceeded, tight)

      assert {%{count: 2}, {:escalate, :quota_exceeded, 2}} =
               DeterministicFailure.decide(entry, :quota_exceeded, tight)
    end
  end

  describe "deterministic_codes/0" do
    test "covers the failure codes we expect to escalate on" do
      codes = DeterministicFailure.deterministic_codes()
      assert :quota_exceeded in codes
      assert :context_window_exhausted in codes
      assert :invalid_request in codes
      assert :claude_sidecar_exit in codes
      assert :port_exit in codes
      refute :rate_limited in codes
      refute :overloaded in codes
      refute :unknown in codes
    end
  end

  describe "compose_message/4" do
    test "alert message names the code and count and references the docs page" do
      body = DeterministicFailure.compose_message(:quota_exceeded, 3, :alert, "Human Review")

      assert body =~ "Deterministic-failure alert"
      assert body =~ "**3** consecutive failures"
      assert body =~ "`quota_exceeded`"
      assert body =~ "elixir/docs/token_exhaustion.md"
      refute body =~ "moving the issue to **Human Review**"
    end

    test "escalation message names the destination state" do
      body = DeterministicFailure.compose_message(:context_window_exhausted, 5, :escalate, "Triage")

      assert body =~ "Deterministic-failure escalation"
      assert body =~ "**5** consecutive failures"
      assert body =~ "`context_window_exhausted`"
      assert body =~ "moving the issue to **Triage**"
    end

    test "includes a stable sentinel marker so re-runs replace the prior block" do
      body = DeterministicFailure.compose_message(:quota_exceeded, 3, :alert, "Human Review")
      assert body =~ "<!-- symphony:deterministic-failure -->"
    end
  end

  describe "handle/3 with memory tracker" do
    setup do
      previous_comments = Application.get_env(:symphony_elixir, :memory_tracker_comments)

      # Force the memory tracker so Tracker dispatches to it.
      previous_kind =
        case Workflow.workflow_file_path() do
          path when is_binary(path) ->
            content = File.read!(path)
            File.write!(path, String.replace(content, ~s(kind: "linear"), ~s(kind: "memory")))

            if Process.whereis(SymphonyElixir.WorkflowStore) do
              SymphonyElixir.WorkflowStore.force_reload()
            end

            :linear

          _ ->
            nil
        end

      Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

      on_exit(fn ->
        Application.delete_env(:symphony_elixir, :memory_tracker_recipient)

        case previous_comments do
          nil -> Application.delete_env(:symphony_elixir, :memory_tracker_comments)
          value -> Application.put_env(:symphony_elixir, :memory_tracker_comments, value)
        end

        if previous_kind do
          # The TestSupport on_exit hooks will rebuild WORKFLOW.md from
          # scratch for the next test, so no extra restore needed here.
          :ok
        end
      end)

      issue = %Issue{
        id: "issue-det-1",
        identifier: "ENT-1",
        title: "Stuck issue",
        state: "In Progress",
        url: "https://example.org/issues/ENT-1"
      }

      {:ok, issue: issue}
    end

    test "alert with no existing workpad creates a standalone blocker comment", %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{})

      assert :ok = DeterministicFailure.handle({:alert, :quota_exceeded, 3}, issue, settings())

      assert_received {:memory_tracker_comment, "issue-det-1", body}
      assert body =~ "Symphony Deterministic Failure Alert"
      assert body =~ "Error code: `quota_exceeded`"
      assert body =~ "Consecutive failures: **3**"
      refute_received {:memory_tracker_state_update, _, _}
    end

    test "alert with existing workpad updates the workpad comment instead of creating a new one",
         %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-det-1" => [
          %{
            id: "workpad-1",
            body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do the thing\n",
            resolved_at: nil
          }
        ]
      })

      assert :ok = DeterministicFailure.handle({:alert, :quota_exceeded, 3}, issue, settings())

      assert_received {:memory_tracker_comment_update, "workpad-1", new_body}
      assert new_body =~ "## Symphony Workpad"
      assert new_body =~ "### Deterministic-failure alert"
      assert new_body =~ "<!-- symphony:deterministic-failure -->"
      assert new_body =~ "`quota_exceeded`"
      refute_received {:memory_tracker_comment, _, _}
    end

    test "resolved workpad comments are ignored — falls back to create_comment", %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-det-1" => [
          %{
            id: "workpad-resolved",
            body: "## Symphony Workpad\n\nold and resolved",
            resolved_at: "2024-12-01T00:00:00Z"
          }
        ]
      })

      assert :ok = DeterministicFailure.handle({:alert, :quota_exceeded, 3}, issue, settings())

      assert_received {:memory_tracker_comment, "issue-det-1", body}
      assert body =~ "Symphony Deterministic Failure Alert"
      refute_received {:memory_tracker_comment_update, _, _}
    end

    test "escalation posts the comment AND moves the issue to the escalation state", %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-det-1" => [
          %{
            id: "workpad-2",
            body: "## Symphony Workpad\n\n### Plan\n\n- [ ] do",
            resolved_at: nil
          }
        ]
      })

      assert {:ok, :escalated} =
               DeterministicFailure.handle(
                 {:escalate, :context_window_exhausted, 5},
                 issue,
                 settings(%{
                   deterministic_failure_escalation_state: "Human Review"
                 })
               )

      assert_received {:memory_tracker_comment_update, "workpad-2", new_body}
      assert new_body =~ "Deterministic-failure escalation"
      assert new_body =~ "`context_window_exhausted`"
      assert_received {:memory_tracker_state_update, "issue-det-1", "Human Review"}
    end

    test "subsequent escalations replace the prior failure block rather than duplicate it",
         %{issue: issue} do
      Application.put_env(:symphony_elixir, :memory_tracker_comments, %{
        "issue-det-1" => [
          %{
            id: "workpad-3",
            body: """
            ## Symphony Workpad

            ### Plan

            - [ ] do the thing

            <!-- symphony:deterministic-failure -->

            ### Deterministic-failure alert

            Stale alert from a previous streak — should be replaced.
            """,
            resolved_at: nil
          }
        ]
      })

      assert :ok = DeterministicFailure.handle({:alert, :quota_exceeded, 3}, issue, settings())

      assert_received {:memory_tracker_comment_update, "workpad-3", new_body}
      assert new_body =~ "## Symphony Workpad"
      assert new_body =~ "### Plan"
      assert new_body =~ "- [ ] do the thing"
      assert new_body =~ "`quota_exceeded`"

      sentinel_occurrences =
        new_body
        |> String.split("<!-- symphony:deterministic-failure -->")
        |> length()
        |> Kernel.-(1)

      assert sentinel_occurrences == 1,
             "expected exactly one failure-block sentinel, got #{sentinel_occurrences}:\n#{new_body}"

      refute new_body =~ "Stale alert from a previous streak"
    end
  end
end
