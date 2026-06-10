defmodule SymphonyElixir.AgentAdapterDispatchTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config

  defp write_workflow_with_agent_block!(extra_yaml) do
    body = """
    ---
    tracker:
      kind: linear
      api_key: token
      project_slug: project
    workspace:
      root: #{Path.join(System.tmp_dir!(), "symphony_workspaces")}
    #{extra_yaml}
    ---
    You are a coding agent.
    """

    File.write!(Workflow.workflow_file_path(), body)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()
  end

  test "Config.adapter_module/0 defaults to Codex.AppServer when agent.kind unset" do
    write_workflow_with_agent_block!("agent:\n  max_concurrent_agents: 1\n")
    assert Config.adapter_module() == SymphonyElixir.Codex.AppServer
  end

  test "Config.adapter_module/0 returns Claude.AppServer when agent.kind == claude" do
    write_workflow_with_agent_block!("agent:\n  kind: claude\n")
    assert Config.adapter_module() == SymphonyElixir.Claude.AppServer
  end

  test "Config.adapter_module/0 returns Codex.AppServer when agent.kind == codex" do
    write_workflow_with_agent_block!("agent:\n  kind: codex\n")
    assert Config.adapter_module() == SymphonyElixir.Codex.AppServer
  end

  describe "preflight validation for Claude" do
    setup do
      previous = %{
        api_key: System.get_env("ANTHROPIC_API_KEY"),
        auth_token: System.get_env("ANTHROPIC_AUTH_TOKEN"),
        oauth: System.get_env("CLAUDE_CODE_OAUTH_TOKEN"),
        home: System.get_env("HOME"),
        config_dir: System.get_env("CLAUDE_CONFIG_DIR"),
        bedrock: System.get_env("CLAUDE_CODE_USE_BEDROCK"),
        vertex: System.get_env("CLAUDE_CODE_USE_VERTEX"),
        foundry: System.get_env("CLAUDE_CODE_USE_FOUNDRY")
      }

      on_exit(fn ->
        restore_env("ANTHROPIC_API_KEY", previous.api_key)
        restore_env("ANTHROPIC_AUTH_TOKEN", previous.auth_token)
        restore_env("CLAUDE_CODE_OAUTH_TOKEN", previous.oauth)
        restore_env("HOME", previous.home)
        restore_env("CLAUDE_CONFIG_DIR", previous.config_dir)
        restore_env("CLAUDE_CODE_USE_BEDROCK", previous.bedrock)
        restore_env("CLAUDE_CODE_USE_VERTEX", previous.vertex)
        restore_env("CLAUDE_CODE_USE_FOUNDRY", previous.foundry)
      end)

      Enum.each(
        ~w(ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
           CLAUDE_CONFIG_DIR CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY),
        &System.delete_env/1
      )

      # Point HOME at an empty tmpdir so any real ~/.claude/.credentials.json
      # on the test host does not silently satisfy the preflight.
      tmp_home =
        Path.join(System.tmp_dir!(), "symphony-claude-auth-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_home)
      System.put_env("HOME", tmp_home)
      on_exit(fn -> File.rm_rf(tmp_home) end)

      {:ok, tmp_home: tmp_home}
    end

    test "validate!/0 fails when no credentials are present" do
      write_workflow_with_agent_block!("agent:\n  kind: claude\n")
      assert {:error, :missing_claude_credentials} = Config.validate!()
    end

    test "validate!/0 succeeds with ANTHROPIC_API_KEY" do
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test")
      write_workflow_with_agent_block!("agent:\n  kind: claude\n")
      assert :ok = Config.validate!()
    end

    test "validate!/0 succeeds with CLAUDE_CODE_OAUTH_TOKEN" do
      System.put_env("CLAUDE_CODE_OAUTH_TOKEN", "oauth-test")
      write_workflow_with_agent_block!("agent:\n  kind: claude\n")
      assert :ok = Config.validate!()
    end

    test "validate!/0 succeeds with a Claude Code credentials file in $HOME/.claude", %{tmp_home: tmp_home} do
      claude_dir = Path.join(tmp_home, ".claude")
      File.mkdir_p!(claude_dir)

      File.write!(
        Path.join(claude_dir, ".credentials.json"),
        ~s({"claudeAiOauth": {"accessToken": "fake", "refreshToken": "fake"}})
      )

      write_workflow_with_agent_block!("agent:\n  kind: claude\n")
      assert :ok = Config.validate!()
    end

    test "validate!/0 ignores a credentials file lacking claudeAiOauth", %{tmp_home: tmp_home} do
      claude_dir = Path.join(tmp_home, ".claude")
      File.mkdir_p!(claude_dir)
      File.write!(Path.join(claude_dir, ".credentials.json"), ~s({"unrelated": true}))

      write_workflow_with_agent_block!("agent:\n  kind: claude\n")
      assert {:error, :missing_claude_credentials} = Config.validate!()
    end

    test "validate!/0 honors CLAUDE_CONFIG_DIR override", %{tmp_home: _} do
      override =
        Path.join(System.tmp_dir!(), "symphony-claude-config-dir-#{System.unique_integer([:positive])}")

      File.mkdir_p!(override)
      on_exit(fn -> File.rm_rf(override) end)

      File.write!(
        Path.join(override, ".credentials.json"),
        ~s({"claudeAiOauth": {"accessToken": "fake"}})
      )

      previous = System.get_env("CLAUDE_CONFIG_DIR")
      System.put_env("CLAUDE_CONFIG_DIR", override)
      on_exit(fn -> restore_env("CLAUDE_CONFIG_DIR", previous) end)

      write_workflow_with_agent_block!("agent:\n  kind: claude\n")
      assert :ok = Config.validate!()
    end

    test "validate!/0 ignores Claude credentials when agent.kind == codex" do
      write_workflow_with_agent_block!("agent:\n  kind: codex\n")
      assert :ok = Config.validate!()
    end

    test "validate!/0 rejects agent.kind == claude with non-empty worker.ssh_hosts" do
      # Claude has no remote-worker support yet (Claude.AppServer always
      # spawns a local bash port). If the orchestrator picked an SSH host
      # under this config, every Claude turn would dispatch and then fail
      # at `start_session` with `{:claude_remote_worker_unsupported, host}`,
      # then retry. Refuse the misconfig at boot instead.
      System.put_env("ANTHROPIC_API_KEY", "sk-ant-test")

      write_workflow_with_agent_block!("""
      worker:
        ssh_hosts:
          - "alice@host"
          - "bob@host"
      agent:
        kind: claude
      """)

      assert {:error, {:claude_remote_worker_unsupported, ["alice@host", "bob@host"]}} =
               Config.validate!()
    end

    test "validate!/0 succeeds when agent.kind == codex with non-empty worker.ssh_hosts" do
      # Regression guard: SSH worker support is the existing Codex path and
      # must keep working after the Claude-incompat check is added.
      write_workflow_with_agent_block!("""
      worker:
        ssh_hosts:
          - "alice@host"
      agent:
        kind: codex
      """)

      assert :ok = Config.validate!()
    end

    test "validate!/0 honors agent.claude.config_dir over CLAUDE_CONFIG_DIR/HOME defaults" do
      override =
        Path.join(System.tmp_dir!(), "symphony-claude-cfg-#{System.unique_integer([:positive])}")

      File.mkdir_p!(override)
      on_exit(fn -> File.rm_rf(override) end)

      File.write!(
        Path.join(override, ".credentials.json"),
        ~s({"claudeAiOauth": {"accessToken": "fake"}})
      )

      write_workflow_with_agent_block!("""
      agent:
        kind: claude
        claude:
          config_dir: "#{override}"
      """)

      assert :ok = Config.validate!()
    end

    test "validate!/0 fails when agent.claude.config_dir lacks credentials" do
      override =
        Path.join(System.tmp_dir!(), "symphony-claude-cfg-empty-#{System.unique_integer([:positive])}")

      File.mkdir_p!(override)
      on_exit(fn -> File.rm_rf(override) end)

      write_workflow_with_agent_block!("""
      agent:
        kind: claude
        claude:
          config_dir: "#{override}"
      """)

      # Even though HOME has no .claude/.credentials.json either, the
      # config_dir override pins us to that empty dir → fail.
      assert {:error, :missing_claude_credentials} = Config.validate!()
    end

    test "validate!/0 expands `~` in agent.claude.config_dir" do
      # `Path.expand("~")` reads the VM-start home and ignores any runtime
      # `HOME` override, so exercising `~` expansion end-to-end requires
      # writing credentials under the real expanded home. Pick a uniquely-
      # named subdirectory rather than `~/.claude` so a clean dev machine
      # (notably macOS, where ambient `~/.claude/.credentials.json` is the
      # usual Claude auth) passes the gate without polluting it.
      tilde_subdir = ".symphony-claude-test-#{System.unique_integer([:positive])}"
      config_dir = Path.expand("~/#{tilde_subdir}")
      File.mkdir_p!(config_dir)
      on_exit(fn -> File.rm_rf(config_dir) end)

      File.write!(
        Path.join(config_dir, ".credentials.json"),
        ~s({"claudeAiOauth": {"accessToken": "fake"}})
      )

      write_workflow_with_agent_block!("""
      agent:
        kind: claude
        claude:
          config_dir: "~/#{tilde_subdir}"
      """)

      assert :ok = Config.validate!()
    end
  end
end
