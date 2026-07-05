defmodule SymphonyElixir.CodexAppServerTimeoutTest do
  @moduledoc """
  Drives the Elixir-side Codex adapter against scripted bash subprocesses that
  emit JSON-RPC lines mimicking the Codex app-server. This keeps the test
  suite hermetic — no Codex binary required.

  Covers two `run_turn/4` timeout defects (see `AppServer.run_turn/4` and
  `receive_loop/4`):

    1. `:turn_timeout_ms` passed via `opts` must actually bound the turn,
       even when the global `codex.turn_timeout_ms` config is much larger.
    2. The bound must be an absolute wall-clock deadline, not a per-message
       inactivity timeout — a turn that keeps emitting non-terminal
       notifications faster than the timeout must still time out once total
       elapsed time exceeds it.
  """

  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Linear.Issue

  # Scripted command that handles the full init handshake (initialize →
  # initialized → thread/start → turn/start) and then idles on stdin without
  # ever emitting a turn-terminal event.
  defp scripted_idle_command do
    ~s|(IFS= read -r _; echo '{"id":1,"result":{}}';| <>
      " IFS= read -r _;" <>
      ~s| IFS= read -r _; echo '{"id":2,"result":{"thread":{"id":"th1"}}}';| <>
      ~s| IFS= read -r _; echo '{"id":3,"result":{"turn":{"id":"tu1"}}}';| <>
      " while IFS= read -r _; do :; done)"
  end

  # Scripted command that, after the handshake, emits a stream of
  # non-terminal notifications every ~40ms for ~1.6s (well past any of the
  # small `turn_timeout_ms` values used below) before idling. A correct
  # absolute-deadline implementation must not let this chatter reset its
  # clock.
  defp scripted_chatter_command do
    ~s|(IFS= read -r _; echo '{"id":1,"result":{}}';| <>
      " IFS= read -r _;" <>
      ~s| IFS= read -r _; echo '{"id":2,"result":{"thread":{"id":"th1"}}}';| <>
      ~s| IFS= read -r _; echo '{"id":3,"result":{"turn":{"id":"tu1"}}}';| <>
      ~s| i=0; while [ "$i" -lt 40 ]; do echo '{"method":"codex/event/agent_message_delta","params":{}}'; sleep 0.04; i=$((i+1)); done;| <>
      " while IFS= read -r _; do :; done)"
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "MT-1", title: "test", state: "Todo", description: nil}
  end

  setup do
    # The default workspace_root in TestSupport is Path.join(System.tmp_dir!, "symphony_workspaces").
    # Create a unique child directory under that root so validate_workspace_cwd passes.
    workspace_root = Path.join(System.tmp_dir!(), "symphony_workspaces")
    workspace = Path.join(workspace_root, "codex-timeout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  defp set_codex_command(cmd, overrides \\ []) do
    write_workflow_file!(
      SymphonyElixir.Workflow.workflow_file_path(),
      Keyword.merge(
        [
          codex_command: cmd,
          codex_read_timeout_ms: 2_000,
          # Deliberately huge so a test that (incorrectly) falls back to the
          # global config timeout instead of honoring `opts[:turn_timeout_ms]`
          # would hang for an hour instead of returning quickly.
          codex_turn_timeout_ms: 3_600_000
        ],
        overrides
      )
    )
  end

  test "run_turn honors a small turn_timeout_ms opt even though the global config timeout is large", %{
    workspace: workspace
  } do
    set_codex_command(scripted_idle_command())

    {:ok, session} = AppServer.start_session(workspace)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :turn_timeout} =
             AppServer.run_turn(session, "Go", issue(), turn_timeout_ms: 200)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert elapsed_ms < 3_000,
           "expected run_turn to honor the small turn_timeout_ms opt instead of the 3_600_000ms " <>
             "global config timeout, but it took #{elapsed_ms}ms"

    AppServer.stop_session(session)
  end

  test "run_turn enforces an absolute wall-clock deadline, not a per-message inactivity timeout", %{
    workspace: workspace
  } do
    set_codex_command(scripted_chatter_command())

    {:ok, session} = AppServer.start_session(workspace)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, :turn_timeout} =
             AppServer.run_turn(session, "Go", issue(), turn_timeout_ms: 300)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    # The scripted subprocess keeps emitting notifications every ~40ms for
    # ~1.6s total. An inactivity-timeout implementation resets its clock on
    # every message and would not time out until the chatter stops (~1.6s)
    # plus one more inactivity window — well past 1s. An absolute-deadline
    # implementation returns shortly after the 300ms deadline regardless.
    assert elapsed_ms < 1_000,
           "expected run_turn to enforce an absolute wall-clock deadline instead of resetting " <>
             "on every message, but it took #{elapsed_ms}ms"

    AppServer.stop_session(session)
  end
end
