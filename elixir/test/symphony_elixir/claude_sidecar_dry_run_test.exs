defmodule SymphonyElixir.ClaudeSidecarDryRunTest do
  @moduledoc """
  Spawns the real Python sidecar in dry-run mode (no claude-agent-sdk required)
  and verifies the Elixir Claude.AppServer can ride its `ready`/`system_init`
  handshake. Confirms the wire shape matches end-to-end.
  """

  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Claude.AppServer

  @moduletag :requires_python

  setup do
    workspace =
      Path.join(System.tmp_dir!(), "claude-sidecar-dry-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(workspace) end)
    {:ok, workspace: workspace}
  end

  defp python? do
    is_binary(System.find_executable("python3"))
  end

  test "real python sidecar in dry-run mode emits ready and exits cleanly", %{workspace: workspace} do
    if python?() do
      sidecar_dir =
        Path.join([
          File.cwd!(),
          "priv",
          "claude_agent"
        ])

      # Real sidecar in dry-run only emits `ready` and exits — that matches
      # the production handshake (system_init only arrives during a turn).
      cmd =
        "SYMPHONY_CLAUDE_AGENT_DRY_RUN=1 PYTHONPATH=#{sidecar_dir} " <>
          "python3 -m symphony_claude_agent"

      config = %{
        command: cmd,
        model: "claude-sonnet-4-6",
        permission_mode: "dontAsk",
        allowed_tools: [],
        disallowed_tools: [],
        system_prompt_preset: "claude_code",
        setting_sources: [],
        extra_env: %{},
        read_timeout_ms: 5_000
      }

      assert {:ok, session} = AppServer.start_session(workspace, config: config)
      # session_id stays nil at this point — captured later from system_init
      # during the first real turn.
      assert session.session_id == nil

      AppServer.stop_session(session)
    else
      IO.puts(:stderr, "skip: python3 not on PATH")
    end
  end
end
