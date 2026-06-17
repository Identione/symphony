defmodule SymphonyElixir.AgentRunnerCoverageTest do
  @moduledoc """
  Behavioral coverage for `SymphonyElixir.AgentRunner` (IDE-116).

  Two layers:

    * Pure log/fold helpers exercised through the public `log_claude_event/2`
      and `compose_message_handler/4` seams — covering the `system_init`,
      `:fold`/`:fold_quote` non-binary fallbacks, the short-string `cap/2`
      branch, and the catch-all envelope clauses.
    * Full `run/3` turns driven through an injected stub adapter (the
      documented `:adapter` opt) plus an injected `:issue_state_fetcher`,
      covering the continuation state-machine branches: refresh error,
      empty refresh result, terminal-on-refresh, and the
      `active_issue_state?/1` non-binary guard.
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentRunner
  alias SymphonyElixir.Linear.Issue

  # ------------------------------------------------------------------
  # Stub adapter: a minimal `SymphonyElixir.Agent.Adapter` that records
  # the prompts/turns it ran and lets each test script per-turn results
  # and the stop behaviour via the process dictionary of the test pid.
  # ------------------------------------------------------------------
  defmodule StubAdapter do
    @moduledoc false
    @behaviour SymphonyElixir.Agent.Adapter

    @impl true
    def start_session(_workspace, _opts), do: {:ok, %{session: :stub}}

    @impl true
    def run_turn(_session, prompt, _issue, opts) do
      owner = Application.get_env(:symphony_elixir, :stub_adapter_owner)
      send(owner, {:stub_run_turn, prompt})

      if cb = opts[:on_message] do
        cb.(%{event: :session_started, payload: %{}})
      end

      {:ok, %{session_id: "stub-session"}}
    end

    @impl true
    def stop_session(_session) do
      owner = Application.get_env(:symphony_elixir, :stub_adapter_owner)
      send(owner, :stub_stop_session)
      :ok
    end
  end

  # A workspace_root + git template repo + after_create hook, mirroring the
  # existing integration tests so `Workspace.create_for_issue/2` succeeds
  # without a real codex/claude subprocess.
  defp setup_workspace! do
    test_root =
      Path.join(
        System.tmp_dir!(),
        "symphony-agent-runner-cov-#{System.unique_integer([:positive])}"
      )

    template_repo = Path.join(test_root, "source")
    workspace_root = Path.join(test_root, "workspaces")

    File.mkdir_p!(template_repo)
    File.write!(Path.join(template_repo, "README.md"), "# test")
    System.cmd("git", ["-C", template_repo, "init", "-b", "main"])
    System.cmd("git", ["-C", template_repo, "config", "user.name", "Test User"])
    System.cmd("git", ["-C", template_repo, "config", "user.email", "test@example.com"])
    System.cmd("git", ["-C", template_repo, "add", "README.md"])
    System.cmd("git", ["-C", template_repo, "commit", "-m", "initial"])

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root, template_repo: template_repo, workspace_root: workspace_root}
  end

  defp write_stub_workflow!(%{template_repo: template_repo, workspace_root: workspace_root}, overrides) do
    Application.put_env(:symphony_elixir, :stub_adapter_owner, self())
    on_exit(fn -> Application.delete_env(:symphony_elixir, :stub_adapter_owner) end)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      Keyword.merge(
        [
          workspace_root: workspace_root,
          hook_after_create: "cp #{Path.join(template_repo, "README.md")} README.md"
        ],
        overrides
      )
    )
  end

  defp issue(state \\ "In Progress") do
    %Issue{
      id: "issue-cov-1",
      identifier: "COV-1",
      title: "Coverage issue",
      description: "desc",
      state: state,
      url: "https://example.org/issues/COV-1",
      labels: []
    }
  end

  defp claude_event(type, payload, session_id \\ "sess-cov") do
    %{event: type, session_id: session_id, payload: payload, timestamp: DateTime.utc_now()}
  end

  defp claude_handler(opts \\ [verbose_logging: true]) do
    AgentRunner.compose_message_handler(SymphonyElixir.Claude.AppServer, self(), issue(), opts)
  end

  describe "log_claude_event/2 — verbose Claude log lines" do
    test "logs `system_init` with the issue/session context" do
      log =
        capture_log(fn ->
          claude_handler().(claude_event(:system_init, %{}))
        end)

      assert log =~ "claude system_init"
      assert log =~ "issue_identifier=COV-1"
      assert log =~ "session_id=sess-cov"
    end

    test "ignores envelopes without an `:event`/`:payload` shape" do
      # Drives the `log_claude_event(_issue, _other)` catch-all (returns :ok)
      # and the verbose handler still forwards the raw message downstream.
      handler = claude_handler()
      assert :ok = AgentRunner.log_claude_event(issue(), %{not: :an_event})

      log = capture_log(fn -> handler.(%{shape: :unknown}) end)
      assert log == "", "unrecognized envelope should emit no log line, got: #{log}"
    end

    test "ignores recognized-shape envelopes with an unknown event type" do
      # Drives `log_claude_event_line(_other, _ctx, _payload)` catch-all.
      log =
        capture_log(fn ->
          claude_handler().(claude_event(:some_future_event, %{anything: 1}))
        end)

      assert log == "", "unknown event type should emit no log line, got: #{log}"
    end

    test "folds a non-binary tool_call input via Jason and quotes a map text" do
      # `tool_call` with a JSON-encodable map input drives the `fold/1`
      # encode-success branch.
      log =
        capture_log(fn ->
          claude_handler().(claude_event(:tool_call, %{name: "Read", input: %{"path" => "/x"}}))
        end)

      assert log =~ "claude tool_call"
      assert log =~ "name=Read"
      assert log =~ ~s("path")
    end

    test "folds an un-encodable tool_call input via inspect fallback" do
      # A tuple is not JSON-encodable, so `fold/1` falls through to the
      # `inspect/2` branch (the previously-uncovered `_ ->` clause).
      log =
        capture_log(fn ->
          claude_handler().(claude_event(:tool_call, %{name: "Weird", input: {:not, "json"}}))
        end)

      assert log =~ "claude tool_call"
      assert log =~ "name=Weird"
      # inspect/2 of the tuple appears verbatim.
      assert log =~ ~s({:not, "json"})
    end

    test "quotes a nil assistant_message text and a non-binary text via inspect" do
      # nil text -> `fold_quote(nil)` -> empty quotes.
      log_nil =
        capture_log(fn ->
          claude_handler().(claude_event(:assistant_message, %{text: nil}))
        end)

      assert log_nil =~ ~s(text="")

      # non-binary text -> `fold_quote(value)` inspect branch.
      log_int =
        capture_log(fn ->
          claude_handler().(claude_event(:assistant_message, %{text: 42}))
        end)

      assert log_int =~ ~s(text="42")
    end

    test "permission_request with nil request folds to empty" do
      # `fold(nil)` -> "" (the previously-uncovered nil clause).
      log =
        capture_log(fn ->
          claude_handler().(claude_event(:permission_request, %{request: nil}))
        end)

      assert log =~ "claude permission_request"
      assert log =~ "request="
    end

    test "permission_request with a short binary request hits the cap short-circuit" do
      # A short binary string drives `cap/2`'s `byte_size <= limit` branch
      # (returns the string unchanged) via `fold/1`'s binary clause.
      log =
        capture_log(fn ->
          claude_handler().(claude_event(:permission_request, %{request: "tiny"}))
        end)

      assert log =~ "claude permission_request"
      assert log =~ "request=tiny"
    end

    test "multi-byte text over the byte limit but under the grapheme limit is not truncated" do
      # 200 two-byte graphemes = 400 bytes > 256-byte limit, but
      # String.length == 200 <= 256, so `cap/2` takes its second
      # `length <= limit -> string` branch and returns the value whole
      # (no `…(N more chars)` suffix).
      multibyte = String.duplicate("é", 200)
      assert byte_size(multibyte) > 256
      assert String.length(multibyte) <= 256

      log =
        capture_log(fn ->
          claude_handler().(claude_event(:assistant_message, %{text: multibyte}))
        end)

      assert log =~ "claude assistant_message"
      assert log =~ multibyte
      refute log =~ "more chars"
    end
  end

  describe "run/3 continuation state machine (stub adapter)" do
    test "stops after one turn when the issue refreshes to a terminal state" do
      ctx = setup_workspace!()
      write_stub_workflow!(ctx, max_turns: 5)

      fetcher = fn ["issue-cov-1"] -> {:ok, [%{issue() | state: "Done"}]} end

      assert :ok =
               AgentRunner.run(issue(), nil,
                 adapter: StubAdapter,
                 issue_state_fetcher: fetcher
               )

      # Exactly one turn ran, then the session stopped (terminal refresh ->
      # the `{:done, _}` branch).
      assert_received {:stub_run_turn, _prompt}
      refute_received {:stub_run_turn, _other}
      assert_received :stub_stop_session
    end

    test "treats an empty refresh result as done (stops after one turn)" do
      ctx = setup_workspace!()
      write_stub_workflow!(ctx, max_turns: 5)

      # Empty list -> `{:ok, []}` branch -> `{:done, issue}`.
      fetcher = fn ["issue-cov-1"] -> {:ok, []} end

      assert :ok =
               AgentRunner.run(issue(), nil,
                 adapter: StubAdapter,
                 issue_state_fetcher: fetcher
               )

      assert_received {:stub_run_turn, _prompt}
      refute_received {:stub_run_turn, _other}
      assert_received :stub_stop_session
    end

    test "surfaces an issue-state refresh failure as an exit and still stops the session" do
      ctx = setup_workspace!()
      write_stub_workflow!(ctx, max_turns: 5)

      # `{:error, reason}` from the fetcher -> `continue_with_issue?` returns
      # `{:error, {:issue_state_refresh_failed, reason}}`, which propagates up
      # through `handle_turn_continuation`'s `{:error, reason}` branch and
      # `do_run_codex_turns`'s `with` failure, becoming a non-:ok `run_turn`
      # result that `run/3` classifies and exits on.
      fetcher = fn ["issue-cov-1"] -> {:error, :boom} end

      reason =
        catch_exit(
          AgentRunner.run(issue(), nil,
            adapter: StubAdapter,
            issue_state_fetcher: fetcher
          )
        )

      assert {:agent_run_failed, :unknown, {:issue_state_refresh_failed, :boom}} = reason

      # The session is always stopped in the `after` clause even on failure.
      assert_received {:stub_run_turn, _prompt}
      assert_received :stub_stop_session
    end

    test "treats a non-binary issue state on refresh as inactive (done)" do
      ctx = setup_workspace!()
      write_stub_workflow!(ctx, max_turns: 5)

      # A refreshed issue whose `state` is not a binary drives the
      # `active_issue_state?(_state_name) -> false` guard, so the run stops.
      fetcher = fn ["issue-cov-1"] -> {:ok, [%{issue() | state: nil}]} end

      assert :ok =
               AgentRunner.run(issue(), nil,
                 adapter: StubAdapter,
                 issue_state_fetcher: fetcher
               )

      assert_received {:stub_run_turn, _prompt}
      refute_received {:stub_run_turn, _other}
      assert_received :stub_stop_session
    end

    test "exits with :max_turns_reached when the cap is hit while the issue is still active (IDE-74)" do
      ctx = setup_workspace!()
      # `max_turns: 1` guarantees the very first turn-continuation check is
      # the cap-hit branch (`turn_number == max_turns`) so we don't have to
      # script multiple turns to reach it.
      write_stub_workflow!(ctx, max_turns: 1)

      fetcher = fn ["issue-cov-1"] -> {:ok, [issue()]} end

      reason =
        catch_exit(
          AgentRunner.run(issue(), nil,
            adapter: StubAdapter,
            issue_state_fetcher: fetcher
          )
        )

      assert {:agent_run_failed, :max_turns_reached, :max_turns_reached} = reason

      assert_received {:stub_run_turn, _prompt}
      refute_received {:stub_run_turn, _other}
      assert_received :stub_stop_session
    end

    test "returns :ok when the cap is hit but the issue has moved to a terminal state (IDE-74)" do
      ctx = setup_workspace!()
      write_stub_workflow!(ctx, max_turns: 1)

      # max_turns exhausted AND issue moved out → `{:done, _}` arm wins over
      # the `:max_turns_reached` arm: the cap-hit signal must not fire if the
      # run organically wrapped up the issue.
      fetcher = fn ["issue-cov-1"] -> {:ok, [%{issue() | state: "Done"}]} end

      assert :ok =
               AgentRunner.run(issue(), nil,
                 adapter: StubAdapter,
                 issue_state_fetcher: fetcher
               )

      assert_received {:stub_run_turn, _prompt}
      refute_received {:stub_run_turn, _other}
      assert_received :stub_stop_session
    end
  end

  describe "rebase-on-resume directive" do
    test "prepend_resume_after_block_directive/2 prepends the pull-skill directive with blocker ids" do
      prompt =
        AgentRunner.prepend_resume_after_block_directive("ORIGINAL PROMPT", %{blockers: ["BLK-1", "BLK-2"]})

      assert prompt =~ "Rebase-on-resume guidance:"
      assert prompt =~ "previously paused because it was blocked"
      assert prompt =~ "BLK-1, BLK-2"
      assert prompt =~ "`pull` skill"
      # The original prompt is preserved verbatim, after the directive.
      assert String.ends_with?(prompt, "ORIGINAL PROMPT")
      assert String.starts_with?(prompt, "Rebase-on-resume guidance:")
    end

    test "prepend_resume_after_block_directive/2 falls back to a generic clause without blocker ids" do
      prompt = AgentRunner.prepend_resume_after_block_directive("X", %{blockers: []})

      assert prompt =~ "The issue that blocked it has now landed"
      assert String.ends_with?(prompt, "X")
    end

    test "prepend_resume_after_block_directive/2 is a no-op when no resume info is given" do
      assert AgentRunner.prepend_resume_after_block_directive("X", nil) == "X"
    end

    test "run/3 injects the directive into the turn-1 prompt when resume_after_block is set" do
      ctx = setup_workspace!()
      write_stub_workflow!(ctx, max_turns: 1)

      fetcher = fn ["issue-cov-1"] -> {:ok, [%{issue() | state: "Done"}]} end

      assert :ok =
               AgentRunner.run(issue(), nil,
                 adapter: StubAdapter,
                 issue_state_fetcher: fetcher,
                 resume_after_block: %{blockers: ["BLK-9"]}
               )

      assert_received {:stub_run_turn, prompt}
      assert prompt =~ "Rebase-on-resume guidance:"
      assert prompt =~ "BLK-9"
    end

    test "run/3 leaves the turn-1 prompt untouched without resume_after_block" do
      ctx = setup_workspace!()
      write_stub_workflow!(ctx, max_turns: 1)

      fetcher = fn ["issue-cov-1"] -> {:ok, [%{issue() | state: "Done"}]} end

      assert :ok =
               AgentRunner.run(issue(), nil,
                 adapter: StubAdapter,
                 issue_state_fetcher: fetcher
               )

      assert_received {:stub_run_turn, prompt}
      refute prompt =~ "Rebase-on-resume guidance:"
    end
  end

  describe "selected_worker_host/2" do
    test "returns nil when no host is preferred and none is configured" do
      assert AgentRunner.selected_worker_host(nil, []) == nil
    end

    test "keeps an explicitly preferred host even when others are configured" do
      assert AgentRunner.selected_worker_host("worker-x", ["worker-a", "worker-b"]) ==
               "worker-x"
    end

    test "falls back to the first configured host when none is preferred" do
      # Drives the `_ -> List.first(hosts)` branch, including the
      # trim/reject-blank/uniq normalization.
      assert AgentRunner.selected_worker_host(nil, ["  worker-a  ", "worker-a", "worker-b"]) ==
               "worker-a"
    end

    test "returns nil when the preferred host is blank and configured hosts are all blank" do
      # Empty/blank preferred + a hosts list that normalizes to [] drives the
      # `_ when hosts == [] -> nil` branch.
      assert AgentRunner.selected_worker_host("", ["", "   "]) == nil
    end
  end
end
