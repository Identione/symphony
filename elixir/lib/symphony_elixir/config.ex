defmodule SymphonyElixir.Config do
  @moduledoc """
  Runtime configuration loaded from `WORKFLOW.md`.
  """

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  @default_prompt_template """
  You are working on a Linear issue.

  Identifier: {{ issue.identifier }}
  Title: {{ issue.title }}

  Body:
  {% if issue.description %}
  {{ issue.description }}
  {% else %}
  No description provided.
  {% endif %}
  """

  @type codex_runtime_settings :: %{
          approval_policy: String.t() | map(),
          thread_sandbox: String.t() | nil,
          turn_sandbox_policy: map() | nil
        }

  @spec settings() :: {:ok, Schema.t()} | {:error, term()}
  def settings do
    case Workflow.current() do
      {:ok, %{config: config}} when is_map(config) ->
        Schema.parse(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec settings!() :: Schema.t()
  def settings! do
    case settings() do
      {:ok, settings} ->
        settings

      {:error, reason} ->
        raise ArgumentError, message: format_config_error(reason)
    end
  end

  @spec max_concurrent_agents_for_state(term()) :: pos_integer()
  def max_concurrent_agents_for_state(state_name) when is_binary(state_name) do
    config = settings!()

    Map.get(
      config.agent.max_concurrent_agents_by_state,
      Schema.normalize_issue_state(state_name),
      config.agent.max_concurrent_agents
    )
  end

  def max_concurrent_agents_for_state(_state_name), do: settings!().agent.max_concurrent_agents

  @doc "Turns-from-cap threshold at which budget-pressure steering is injected (`0` disables)."
  @spec budget_pressure_turns() :: non_neg_integer()
  def budget_pressure_turns, do: settings!().agent.budget_pressure_turns

  @doc "Whether to snapshot a dirty working tree to a WIP commit/ref before a session stop."
  @spec preserve_uncommitted_work?() :: boolean()
  def preserve_uncommitted_work?, do: settings!().agent.preserve_uncommitted_work

  @doc "Whether to also create a visible `symphony/wip/<id>` branch when preserving."
  @spec preserve_uncommitted_work_branch?() :: boolean()
  def preserve_uncommitted_work_branch?, do: settings!().agent.preserve_uncommitted_work_branch

  @doc "Timeout (ms) for the non-destructive preservation git-shell invocation."
  @spec cutoff_timeout_ms() :: pos_integer()
  def cutoff_timeout_ms, do: settings!().agent.cutoff_timeout_ms

  @doc "Whether per-turn deterministic progress signals (IDE-211 Layer 1) are computed."
  @spec progress_signal_enabled?() :: boolean()
  def progress_signal_enabled?, do: settings!().agent.progress_signal_enabled

  @doc "Window K for progress-signal streaks and the `at_risk_no_commits` turn floor."
  @spec progress_signal_window_k() :: pos_integer()
  def progress_signal_window_k, do: settings!().agent.progress_signal_window_k

  @doc "Timeout (ms) for the per-turn progress-signal git probe."
  @spec progress_signal_git_timeout_ms() :: pos_integer()
  def progress_signal_git_timeout_ms, do: settings!().agent.progress_signal_git_timeout_ms

  @doc "Turn floor for the `at_risk_no_commits` arm of `ProgressSignal.trigger?/2`."
  @spec progress_trigger_min_turns() :: pos_integer()
  def progress_trigger_min_turns, do: settings!().agent.progress_trigger_min_turns

  @doc "Layer 2 AI overseer config block (IDE-212)."
  @spec overseer() :: SymphonyElixir.Config.Schema.Overseer.t()
  def overseer, do: settings!().agent.overseer

  @doc "Whether the Layer 2 overseer is enabled *and* has a resolved API key."
  @spec overseer_enabled?() :: boolean()
  def overseer_enabled? do
    ov = overseer()
    ov.enabled and is_binary(ov.api_key) and ov.api_key != ""
  end

  @spec codex_turn_sandbox_policy(Path.t() | nil) :: map()
  def codex_turn_sandbox_policy(workspace \\ nil) do
    case Schema.resolve_runtime_turn_sandbox_policy(settings!(), workspace) do
      {:ok, policy} ->
        policy

      {:error, reason} ->
        raise ArgumentError, message: "Invalid codex turn sandbox policy: #{inspect(reason)}"
    end
  end

  @spec workflow_prompt() :: String.t()
  def workflow_prompt do
    case Workflow.current() do
      {:ok, %{prompt_template: prompt}} ->
        if String.trim(prompt) == "", do: @default_prompt_template, else: prompt

      _ ->
        @default_prompt_template
    end
  end

  @spec server_port() :: non_neg_integer() | nil
  def server_port do
    case Application.get_env(:symphony_elixir, :server_port_override) do
      port when is_integer(port) and port >= 0 -> port
      _ -> settings!().server.port
    end
  end

  @doc """
  Resolve the coding-agent adapter module to use for new sessions, based on
  `agent.kind` (SPEC.md §10.1). Defaults to `SymphonyElixir.Codex.AppServer`.
  """
  @spec adapter_module() :: module()
  def adapter_module do
    case settings!().agent.kind do
      "claude" -> SymphonyElixir.Claude.AppServer
      _ -> SymphonyElixir.Codex.AppServer
    end
  end

  @doc """
  Human-readable label for the active coding agent, based on `agent.kind`
  (SPEC.md §10.1). Used in prompts that name the agent to itself. Defaults to
  `"Codex"`.
  """
  @spec agent_label() :: String.t()
  def agent_label do
    case settings!().agent.kind do
      "claude" -> "Claude"
      _ -> "Codex"
    end
  end

  @doc "Per-turn timeout (ms) for the active adapter."
  @spec active_turn_timeout_ms(Schema.t()) :: pos_integer()
  def active_turn_timeout_ms(%Schema{} = settings) do
    case settings.agent.kind do
      "claude" -> settings.agent.claude.turn_timeout_ms
      _ -> settings.codex.turn_timeout_ms
    end
  end

  @doc "Stall-detection timeout (ms) for the active adapter."
  @spec active_stall_timeout_ms(Schema.t()) :: non_neg_integer()
  def active_stall_timeout_ms(%Schema{} = settings) do
    case settings.agent.kind do
      "claude" -> settings.agent.claude.stall_timeout_ms
      _ -> settings.codex.stall_timeout_ms
    end
  end

  @doc """
  Stall-detection timeout (ms) applied while a native tool call is in flight.

  Only meaningful for the Claude adapter, whose long native-tool calls (e.g. a
  `Bash` build) are silent to Symphony; Codex streams exec output, so its
  running command keeps the idle timer fresh on its own and needs no tier.
  """
  @spec active_tool_stall_timeout_ms(Schema.t()) :: non_neg_integer()
  def active_tool_stall_timeout_ms(%Schema{} = settings) do
    case settings.agent.kind do
      "claude" -> settings.agent.claude.tool_stall_timeout_ms
      _ -> settings.codex.stall_timeout_ms
    end
  end

  @spec validate!() :: :ok | {:error, term()}
  def validate! do
    with {:ok, settings} <- settings() do
      validate_semantics(settings)
    end
  end

  @spec codex_runtime_settings(Path.t() | nil, keyword()) ::
          {:ok, codex_runtime_settings()} | {:error, term()}
  def codex_runtime_settings(workspace \\ nil, opts \\ []) do
    with {:ok, settings} <- settings() do
      with {:ok, turn_sandbox_policy} <-
             Schema.resolve_runtime_turn_sandbox_policy(settings, workspace, opts) do
        {:ok,
         %{
           approval_policy: settings.codex.approval_policy,
           thread_sandbox: codex_thread_sandbox(settings),
           turn_sandbox_policy: turn_sandbox_policy
         }}
      end
    end
  end

  defp codex_thread_sandbox(%{codex: %{use_configured_permissions: true}}), do: nil
  defp codex_thread_sandbox(settings), do: settings.codex.thread_sandbox

  defp validate_semantics(settings) do
    with :ok <- validate_tracker(settings.tracker),
         :ok <- validate_agent(settings.agent) do
      validate_worker_adapter_compat(settings)
    end
  end

  # Claude has no remote-worker support; pairing it with ssh_hosts would
  # dispatch, fail at start_session, retry, and loop. Refuse at boot.
  defp validate_worker_adapter_compat(%{
         agent: %{kind: "claude"},
         worker: %{ssh_hosts: hosts}
       })
       when is_list(hosts) and hosts != [] do
    {:error, {:claude_remote_worker_unsupported, hosts}}
  end

  defp validate_worker_adapter_compat(_settings), do: :ok

  defp validate_tracker(tracker) do
    cond do
      is_nil(tracker.kind) ->
        {:error, :missing_tracker_kind}

      tracker.kind not in ["linear", "memory"] ->
        {:error, {:unsupported_tracker_kind, tracker.kind}}

      tracker.kind == "linear" and not is_binary(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      tracker.kind == "linear" and not is_binary(tracker.project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        :ok
    end
  end

  defp validate_agent(%{kind: "claude"} = agent) do
    with :ok <- validate_claude_tool_access(agent) do
      if claude_credentials_present?(agent) do
        :ok
      else
        {:error, :missing_claude_credentials}
      end
    end
  end

  defp validate_agent(_agent), do: :ok

  # Deny-all footgun: under `permission_mode: dontAsk` the claude CLI auto-denies
  # any tool not pre-approved, so an empty/absent `allowed_tools` whitelist leaves
  # the agent with no tools at all — every turn would no-op. Refuse the misconfig
  # at boot. The operator either lists `allowed_tools` (whitelist) or sets
  # `permission_mode: bypassPermissions` (allow-all, gated by the jai sandbox +
  # workspace-cwd boundary). Mirrors `validate_worker_adapter_compat/1`: a
  # claude-specific invalid combination caught here, not in the structural schema.
  defp validate_claude_tool_access(%{claude: %{permission_mode: "dontAsk", allowed_tools: tools}})
       when tools in [nil, []] do
    {:error, :claude_dontask_denies_all_tools}
  end

  defp validate_claude_tool_access(_agent), do: :ok

  # Mirrors Claude Code's own auth precedence so a Max/Pro subscriber who is
  # already logged into the `claude` CLI does not need to provision a separate
  # Console API key just to satisfy Symphony's preflight. Order:
  #
  #   1. ANTHROPIC_API_KEY                    (Console API key)
  #   2. ANTHROPIC_AUTH_TOKEN                 (custom auth token)
  #   3. CLAUDE_CODE_OAUTH_TOKEN              (`claude setup-token` long-lived token)
  #   4. CLAUDE_CODE_USE_{BEDROCK,VERTEX,FOUNDRY} + provider creds (cloud routing)
  #   5. agent.claude.config_dir/.credentials.json
  #      OR $CLAUDE_CONFIG_DIR/.credentials.json
  #      OR ~/.claude/.credentials.json
  #      (live Claude Code subscription login with a `claudeAiOauth` entry)
  defp claude_credentials_present?(agent) do
    Enum.any?(
      [
        &claude_api_key_env?/0,
        &claude_oauth_env?/0,
        &claude_provider_routing?/0,
        fn -> claude_oauth_credentials_file?(agent) end
      ],
      fn check -> check.() end
    )
  end

  defp claude_api_key_env? do
    env_present?("ANTHROPIC_API_KEY") or env_present?("ANTHROPIC_AUTH_TOKEN")
  end

  defp claude_oauth_env?, do: env_present?("CLAUDE_CODE_OAUTH_TOKEN")

  defp claude_provider_routing? do
    Enum.any?(
      ["CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"],
      &env_present?/1
    )
  end

  defp claude_oauth_credentials_file?(agent) do
    case claude_credentials_path(agent) do
      nil -> false
      path -> File.exists?(path) and credentials_file_has_oauth?(path)
    end
  end

  defp claude_credentials_path(%{claude: %{config_dir: dir}})
       when is_binary(dir) and dir != "" do
    Path.join(Path.expand(dir), ".credentials.json")
  end

  defp claude_credentials_path(_agent) do
    case System.get_env("CLAUDE_CONFIG_DIR") do
      dir when is_binary(dir) and dir != "" ->
        Path.join(dir, ".credentials.json")

      _ ->
        case System.get_env("HOME") do
          home when is_binary(home) and home != "" ->
            Path.join([home, ".claude", ".credentials.json"])

          _ ->
            nil
        end
    end
  end

  defp credentials_file_has_oauth?(path) do
    with {:ok, body} <- File.read(path),
         {:ok, parsed} <- Jason.decode(body),
         %{} = oauth <- Map.get(parsed, "claudeAiOauth") do
      map_size(oauth) > 0
    else
      _ -> false
    end
  end

  defp env_present?(var) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  defp format_config_error(reason) do
    case reason do
      {:invalid_workflow_config, message} ->
        "Invalid WORKFLOW.md config: #{message}"

      {:missing_workflow_file, path, raw_reason} ->
        "Missing WORKFLOW.md at #{path}: #{inspect(raw_reason)}"

      {:workflow_parse_error, raw_reason} ->
        "Failed to parse WORKFLOW.md: #{inspect(raw_reason)}"

      :workflow_front_matter_not_a_map ->
        "Failed to parse WORKFLOW.md: workflow front matter must decode to a map"

      other ->
        "Invalid WORKFLOW.md config: #{inspect(other)}"
    end
  end
end
