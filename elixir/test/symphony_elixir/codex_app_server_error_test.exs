defmodule SymphonyElixir.CodexAppServerErrorTest do
  @moduledoc """
  Drives the Elixir-side Codex adapter against scripted bash subprocesses that
  emit JSON-RPC lines mimicking the Codex app-server. This keeps the test suite
  hermetic — no Codex binary required.

  The scripted commands must service the full JSON-RPC handshake:
    initialize (r/w) → initialized (read only) → thread/start (r/w) →
    turn/start (r/w) → error event

  Only the error-code classification path is exercised here.
  """

  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Codex.AppServer
  alias SymphonyElixir.Linear.Issue

  # Scripted command that handles the full init handshake and then emits the
  # given event line before idling.
  #
  # Protocol recap (each line is a JSON-RPC message, stdin/stdout over stdio):
  #   1. Read initialize request  → reply {"id":1,"result":{}}
  #   2. Read initialized notification (no reply needed)
  #   3. Read thread/start request  → reply {"id":2,"result":{"thread":{"id":"th1"}}}
  #   4. Read turn/start request    → reply {"id":3,"result":{"turn":{"id":"tu1"}}}
  #   5. Emit the error event, then idle on stdin
  #
  # Uses `echo` (not `printf`) to avoid backslash-escape sequences that would be
  # mis-interpreted by the YAML serialiser when written to the workflow file.
  defp scripted_error_command(event_json) do
    event = "'" <> String.replace(event_json, "'", ~s('"'"')) <> "'"

    # Responses have no single quotes, so single-quoting is safe.
    ~s|(IFS= read -r _; echo '{"id":1,"result":{}}';| <>
      " IFS= read -r _;" <>
      ~s| IFS= read -r _; echo '{"id":2,"result":{"thread":{"id":"th1"}}}';| <>
      ~s| IFS= read -r _; echo '{"id":3,"result":{"turn":{"id":"tu1"}}}';| <>
      " echo #{event};" <>
      " while IFS= read -r _; do :; done)"
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "MT-1", title: "test", state: "Todo", description: nil}
  end

  setup do
    # The default workspace_root in TestSupport is Path.join(System.tmp_dir!, "symphony_workspaces").
    # Create a unique child directory under that root so validate_workspace_cwd passes.
    workspace_root = Path.join(System.tmp_dir!(), "symphony_workspaces")
    workspace = Path.join(workspace_root, "codex-err-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  defp set_codex_command(cmd) do
    write_workflow_file!(
      SymphonyElixir.Workflow.workflow_file_path(),
      codex_command: cmd,
      codex_read_timeout_ms: 2_000,
      codex_turn_timeout_ms: 5_000
    )
  end

  describe "turn/failed error-code classification" do
    for {label, code, error_params} <- [
          {"rate_limited", :rate_limited, %{"error" => %{"code" => "rate_limit_exceeded", "type" => "requests", "status" => 429}}},
          {"context_window_exhausted", :context_window_exhausted, %{"error" => %{"code" => "context_length_exceeded", "type" => "invalid_request_error", "status" => 413}}},
          {"overloaded", :overloaded, %{"error" => %{"code" => "api_overloaded", "type" => "overloaded_error", "status" => 503}}},
          {"quota_exceeded", :quota_exceeded, %{"error" => %{"code" => "quota_exceeded", "type" => "billing_error", "status" => 402}}},
          {"invalid_request", :invalid_request, %{"error" => %{"code" => "invalid_request", "type" => "invalid_request_error", "status" => 400}}},
          {"unknown", :unknown, %{"error" => %{"code" => "unexpected", "type" => "other", "status" => 500}}}
        ] do
      test "turn/failed with #{label} maps to :#{label}", %{workspace: workspace} do
        code = unquote(code)
        params = unquote(Macro.escape(error_params))

        event = Jason.encode!(%{"method" => "turn/failed", "params" => params})
        set_codex_command(scripted_error_command(event))

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, {:turn_failed, ^code, _params}} =
                 AppServer.run_turn(session, "Go", issue())

        AppServer.stop_session(session)
      end
    end
  end

  describe "codex/event/error error-code classification" do
    for {label, code, error_params} <- [
          {"rate_limited", :rate_limited, %{"error" => %{"code" => "rate_limit_exceeded", "status" => 429}}},
          {"context_window_exhausted", :context_window_exhausted, %{"error" => %{"code" => "context_length_exceeded", "status" => 413}}},
          {"overloaded", :overloaded, %{"error" => %{"code" => "api_overloaded", "type" => "overloaded_error", "status" => 503}}},
          {"quota_exceeded", :quota_exceeded, %{"error" => %{"code" => "quota_exceeded", "status" => 402}}},
          {"invalid_request", :invalid_request, %{"error" => %{"code" => "invalid_request", "status" => 400}}},
          {"unknown", :unknown, %{"error" => %{"code" => "unexpected", "status" => 500}}}
        ] do
      test "codex/event/error with #{label} maps to :#{label}", %{workspace: workspace} do
        code = unquote(code)
        params = unquote(Macro.escape(error_params))

        event = Jason.encode!(%{"method" => "codex/event/error", "params" => params})
        set_codex_command(scripted_error_command(event))

        {:ok, session} = AppServer.start_session(workspace)

        assert {:error, {:codex_error_notification, ^code, _payload}} =
                 AppServer.run_turn(session, "Go", issue())

        AppServer.stop_session(session)
      end
    end
  end
end
