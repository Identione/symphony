defmodule SymphonyElixir.ClaudeAdapterConfigTest do
  use SymphonyElixir.TestSupport
  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Config.Schema.{Agent, Claude}

  defp parse(yaml) do
    {:ok, raw} = YamlElixir.read_from_string(yaml)
    Schema.parse(raw)
  end

  test "agent.kind defaults to codex when unspecified" do
    assert {:ok, settings} = parse(~s|tracker: {kind: linear, project_slug: p, api_key: t}\n|)
    assert settings.agent.kind == "codex"
  end

  test "agent.kind parses claude when set" do
    yaml = """
    tracker: {kind: linear, project_slug: p, api_key: t}
    agent:
      kind: claude
    """

    assert {:ok, settings} = parse(yaml)
    assert settings.agent.kind == "claude"
  end

  test "agent.kind rejects unsupported values" do
    yaml = """
    tracker: {kind: linear, project_slug: p, api_key: t}
    agent:
      kind: gemini
    """

    assert {:error, {:invalid_workflow_config, message}} = parse(yaml)
    assert message =~ "agent.kind"
  end

  test "agent.codex.* mirrors top-level codex defaults" do
    assert {:ok, settings} = parse(~s|tracker: {kind: linear, project_slug: p, api_key: t}\n|)
    assert settings.agent.codex.command == "codex app-server"
    assert settings.agent.codex.turn_timeout_ms == 3_600_000
    assert settings.agent.codex.read_timeout_ms == 5_000
    assert settings.agent.codex.stall_timeout_ms == 300_000
  end

  test "agent.codex.* overrides under nested block" do
    yaml = """
    tracker: {kind: linear, project_slug: p, api_key: t}
    agent:
      codex:
        command: "codex --custom app-server"
        turn_timeout_ms: 1234
    """

    assert {:ok, settings} = parse(yaml)
    assert settings.agent.codex.command == "codex --custom app-server"
    assert settings.agent.codex.turn_timeout_ms == 1234
  end

  test "legacy top-level codex block is still honored when agent.codex is absent" do
    yaml = """
    tracker: {kind: linear, project_slug: p, api_key: t}
    codex:
      command: "legacy-codex app-server"
      turn_timeout_ms: 9876
    """

    assert {:ok, settings} = parse(yaml)
    assert settings.agent.codex.command == "legacy-codex app-server"
    assert settings.agent.codex.turn_timeout_ms == 9876
    # legacy field still readable for back-compat
    assert settings.codex.command == "legacy-codex app-server"
  end

  test "agent.codex.* mirrors up to top-level codex.* for runtime readers" do
    # Runtime readers (Config.codex_runtime_settings/2,
    # Codex.AppServer.run_turn/4, Orchestrator.reconcile_stalled_running_issues/1)
    # all read settings.codex.*. When the user only specifies the new
    # agent.codex layout, those readers must still see the user's values
    # — not schema defaults. Bidirectional alias.
    yaml = """
    tracker: {kind: linear, project_slug: p, api_key: t}
    agent:
      codex:
        command: "nested-codex app-server"
        turn_timeout_ms: 1234
        stall_timeout_ms: 60000
    """

    assert {:ok, settings} = parse(yaml)
    assert settings.codex.command == "nested-codex app-server"
    assert settings.codex.turn_timeout_ms == 1234
    assert settings.codex.stall_timeout_ms == 60_000
  end

  test "agent.claude defaults are present" do
    assert {:ok, settings} = parse(~s|tracker: {kind: linear, project_slug: p, api_key: t}\n|)
    assert settings.agent.claude.permission_mode == "dontAsk"
    assert settings.agent.claude.system_prompt_preset == "claude_code"
    assert settings.agent.claude.allowed_tools == []
    assert settings.agent.claude.disallowed_tools == []
    assert settings.agent.claude.setting_sources == []
    assert settings.agent.claude.turn_timeout_ms == 3_600_000
    assert settings.agent.claude.read_timeout_ms == 30_000
    assert settings.agent.claude.stall_timeout_ms == 300_000
    assert settings.agent.claude.extra_env == %{}
    assert is_binary(settings.agent.claude.command)
    # `verbose_logging=false` keeps Claude's debug feed off by default
    # (SDK partial-message/hook streams, forwarded `claude_cli` stderr,
    # and Symphony's per-envelope log lines all stay quiet); users opt in
    # for debugging.
    assert settings.agent.claude.verbose_logging == false
  end

  test "default command resolves the sidecar via $SYMPHONY_CLAUDE_PRIV_DIR" do
    assert {:ok, settings} = parse(~s|tracker: {kind: linear, project_slug: p, api_key: t}\n|)
    # The sidecar Port spawns with cd:workspace, so a workspace-relative
    # `--project priv/claude_agent` would not resolve. The default uses
    # $SYMPHONY_CLAUDE_PRIV_DIR (injected by Claude.AppServer) so it works
    # regardless of the per-issue workspace cwd.
    assert settings.agent.claude.command =~ "$SYMPHONY_CLAUDE_PRIV_DIR"
    assert settings.agent.claude.command =~ "symphony_claude_agent"
    # Default ships with `jai` so Approach A (outer sandbox containment) works
    # out of the box on Linux 6.13+. Hosts without jai must override
    # `agent.claude.command` to drop the prefix.
    assert String.starts_with?(settings.agent.claude.command, "jai ")
  end

  test "agent.claude accepts overrides" do
    yaml = """
    tracker: {kind: linear, project_slug: p, api_key: t}
    agent:
      kind: claude
      claude:
        command: "uv run python -m my_sidecar"
        model: "claude-sonnet-4-6"
        permission_mode: "acceptEdits"
        allowed_tools: ["Read", "Edit", "Write"]
        disallowed_tools: ["Bash"]
        system_prompt_preset: "minimal"
        setting_sources: ["project"]
        max_turns: 50
        max_budget_usd: 5.5
        extra_env:
          HELLO: world
        turn_timeout_ms: 1800000
        read_timeout_ms: 7000
        stall_timeout_ms: 60000
        verbose_logging: true
    """

    assert {:ok, settings} = parse(yaml)
    claude = settings.agent.claude
    assert claude.command == "uv run python -m my_sidecar"
    assert claude.model == "claude-sonnet-4-6"
    assert claude.permission_mode == "acceptEdits"
    assert claude.allowed_tools == ["Read", "Edit", "Write"]
    assert claude.disallowed_tools == ["Bash"]
    assert claude.system_prompt_preset == "minimal"
    assert claude.setting_sources == ["project"]
    assert claude.max_turns == 50
    assert claude.max_budget_usd == 5.5
    assert claude.extra_env == %{"HELLO" => "world"}
    assert claude.turn_timeout_ms == 1_800_000
    assert claude.read_timeout_ms == 7_000
    assert claude.stall_timeout_ms == 60_000
    assert claude.verbose_logging == true
  end

  test "agent.claude.config_dir defaults to nil" do
    assert {:ok, settings} = parse(~s|tracker: {kind: linear, project_slug: p, api_key: t}\n|)
    assert settings.agent.claude.config_dir == nil
  end

  test "agent.claude.config_dir parses as a string and `~` is preserved for sidecar" do
    yaml = """
    tracker: {kind: linear, project_slug: p, api_key: t}
    agent:
      kind: claude
      claude:
        config_dir: "~/.claude-identione"
    """

    assert {:ok, settings} = parse(yaml)
    assert settings.agent.claude.config_dir == "~/.claude-identione"
  end

  describe "legacy agent.claude.verbose alias" do
    # The original toggle was `agent.claude.verbose`. It was renamed to
    # `verbose_logging` to cover all three noise sources (SDK partial/hook
    # streams, forwarded claude_cli stderr, Symphony per-envelope log lines).
    # `Ecto.Changeset.cast/3` would silently drop the old key and quietly
    # switch users to quiet mode — a UX trap. The schema accepts the legacy
    # key for one release: warn loudly, then map onto `verbose_logging`.

    test "legacy agent.claude.verbose: true migrates to verbose_logging with a warning" do
      yaml = """
      tracker: {kind: linear, project_slug: p, api_key: t}
      agent:
        kind: claude
        claude:
          verbose: true
      """

      log =
        capture_log(fn ->
          assert {:ok, settings} = parse(yaml)
          assert settings.agent.claude.verbose_logging == true
        end)

      assert log =~ "agent.claude.verbose is deprecated"
      assert log =~ "rename to agent.claude.verbose_logging"
    end

    test "legacy agent.claude.verbose: false migrates to verbose_logging: false with a warning" do
      yaml = """
      tracker: {kind: linear, project_slug: p, api_key: t}
      agent:
        kind: claude
        claude:
          verbose: false
      """

      log =
        capture_log(fn ->
          assert {:ok, settings} = parse(yaml)
          assert settings.agent.claude.verbose_logging == false
        end)

      assert log =~ "agent.claude.verbose is deprecated"
    end

    test "agent.claude.verbose_logging takes precedence when both keys are set" do
      yaml = """
      tracker: {kind: linear, project_slug: p, api_key: t}
      agent:
        kind: claude
        claude:
          verbose: false
          verbose_logging: true
      """

      log =
        capture_log(fn ->
          assert {:ok, settings} = parse(yaml)
          assert settings.agent.claude.verbose_logging == true
        end)

      assert log =~ "agent.claude.verbose is deprecated"
      assert log =~ "verbose_logging takes"
    end

    test "no warning when only the new key is set" do
      yaml = """
      tracker: {kind: linear, project_slug: p, api_key: t}
      agent:
        kind: claude
        claude:
          verbose_logging: true
      """

      log =
        capture_log(fn ->
          assert {:ok, settings} = parse(yaml)
          assert settings.agent.claude.verbose_logging == true
        end)

      refute log =~ "deprecated"
    end
  end

  test "agent.claude rejects bad permission_mode" do
    yaml = """
    tracker: {kind: linear, project_slug: p, api_key: t}
    agent:
      kind: claude
      claude:
        permission_mode: "yolo"
    """

    assert {:error, {:invalid_workflow_config, message}} = parse(yaml)
    assert message =~ "agent.claude.permission_mode"
  end

  test "agent.claude rejects bad system_prompt_preset" do
    yaml = """
    tracker: {kind: linear, project_slug: p, api_key: t}
    agent:
      kind: claude
      claude:
        system_prompt_preset: "weird"
    """

    assert {:error, {:invalid_workflow_config, message}} = parse(yaml)
    assert message =~ "agent.claude.system_prompt_preset"
  end

  describe "schema accessors" do
    test "Agent.kinds/0 lists supported adapter kinds" do
      assert Agent.kinds() == ["codex", "claude"]
    end

    test "Claude.permission_modes/0 lists Python SDK permission modes" do
      assert Claude.permission_modes() ==
               ["default", "acceptEdits", "plan", "dontAsk", "bypassPermissions"]
    end

    test "Claude.system_prompt_presets/0 lists supported presets" do
      assert Claude.system_prompt_presets() == ["claude_code", "minimal"]
    end
  end

  describe "agent.kind validation in Agent changeset edge cases" do
    test "agent.codex nested overrides do not require all fields" do
      yaml = """
      tracker: {kind: linear, project_slug: p, api_key: t}
      agent:
        kind: codex
        codex:
          turn_timeout_ms: 7777
      """

      assert {:ok, settings} = parse(yaml)
      assert settings.agent.codex.turn_timeout_ms == 7777
      # Other Codex defaults survive partial nested override
      assert settings.agent.codex.read_timeout_ms == 5_000
    end

    test "legacy top-level codex with nested agent.codex prefers agent.codex" do
      yaml = """
      tracker: {kind: linear, project_slug: p, api_key: t}
      codex:
        command: "legacy"
      agent:
        kind: codex
        codex:
          command: "winner"
      """

      assert {:ok, settings} = parse(yaml)
      # Schema-level: nested wins for settings.agent.codex.* via Agent.changeset
      assert settings.agent.codex.command == "winner"
      # Runtime-level: settings.codex.* must reflect the same winner so the
      # legacy-field readers (codex_runtime_settings/2, Codex.AppServer.run_turn,
      # Orchestrator stall) agree with the schema's stated preference.
      # Without this, "agent.codex wins" is true at the schema layer but
      # false at the runtime layer.
      assert settings.codex.command == "winner"
    end
  end

  describe "Config.active_turn_timeout_ms/1 + Config.active_stall_timeout_ms/1" do
    # AgentRunner and the orchestrator's stall reaper need to pick the
    # timeout matching the active adapter, not always Codex's.
    test "default agent.kind == codex returns codex timeouts" do
      yaml = """
      tracker: {kind: linear, project_slug: p, api_key: t}
      codex:
        turn_timeout_ms: 11111
        stall_timeout_ms: 22222
      """

      assert {:ok, settings} = parse(yaml)
      assert Config.active_turn_timeout_ms(settings) == 11_111
      assert Config.active_stall_timeout_ms(settings) == 22_222
    end

    test "agent.kind == claude returns agent.claude timeouts" do
      yaml = """
      tracker: {kind: linear, project_slug: p, api_key: t}
      agent:
        kind: claude
        claude:
          turn_timeout_ms: 33333
          stall_timeout_ms: 44444
      """

      assert {:ok, settings} = parse(yaml)
      assert Config.active_turn_timeout_ms(settings) == 33_333
      assert Config.active_stall_timeout_ms(settings) == 44_444
    end
  end
end
