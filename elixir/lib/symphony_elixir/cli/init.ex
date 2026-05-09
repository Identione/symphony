defmodule SymphonyElixir.CLI.Init do
  @moduledoc """
  Implements `symphony init` — generates a usable `WORKFLOW.md` from a Linear
  project URL/slug and a repo clone URL.
  """

  alias SymphonyElixir.CLI.LinearProject
  alias SymphonyElixir.Config.Schema

  @switches [
    linear_project: :string,
    repo_url: :string,
    repo_path: :string,
    workspace_root: :string,
    agent: :string,
    output: :string,
    force: :boolean
  ]

  @aliases [o: :output, f: :force]

  @valid_agents Schema.Agent.kinds()
  @setup_url "https://github.com/Identione/symphony/blob/main/SETUP.md"

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  @type deps :: %{
          file_exists?: (Path.t() -> boolean()),
          write: (Path.t(), iodata() -> :ok | {:error, term()}),
          mkdir_p: (Path.t() -> :ok | {:error, term()}),
          puts: (IO.chardata() -> :ok)
        }

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      file_exists?: &File.exists?/1,
      write: &File.write/2,
      mkdir_p: &File.mkdir_p/1,
      puts: fn output -> IO.puts(output) end
    }
  end

  @spec usage_message() :: String.t()
  def usage_message do
    """
    Usage: symphony init \\
      --linear-project <URL_OR_SLUG> \\
      --repo-url <CLONE_URL> \\
      [--workspace-root <PATH>] \\
      [--repo-path <LOCAL_PATH>] \\
      [--agent codex|claude] \\
      [--output <PATH>] \\
      [--force]

      --linear-project   Linear project URL (https://linear.app/<org>/project/<slug>)
                         or bare slug (e.g. symphony-2e32f5d86d8c).
      --repo-url         Git clone URL Symphony hands to the workspace bootstrap hook.
                         Required for the minimal flow — preflight tests it with
                         `git ls-remote`.
      --workspace-root   Where Symphony creates per-issue workspaces. Defaults to
                         ~/code/symphony-workspaces/<repo>.
      --repo-path        Optional local repo path. Symphony itself does not need it;
                         it is exposed for skills that inspect or modify project-local
                         files outside the per-issue workspace.
      --agent            Coding-agent adapter: codex (default) or claude.
      --output           Output path for the generated workflow. Defaults to
                         ./WORKFLOW.md.
      --force            Overwrite an existing output file.
    """
  end

  @spec run([String.t()], deps()) :: :ok | {:error, String.t()}
  def run(args, deps \\ runtime_deps()) do
    case OptionParser.parse(args, strict: @switches, aliases: @aliases) do
      {opts, [], []} ->
        execute(opts, deps)

      {_opts, _positional, [_ | _] = invalid} ->
        {:error, invalid_flags_message(invalid)}

      _ ->
        {:error, usage_message()}
    end
  end

  defp execute(opts, deps) do
    with {:ok, project} <- parse_linear_project(opts),
         {:ok, repo_url} <- require_repo_url(opts),
         {:ok, agent} <- validate_agent(Keyword.get(opts, :agent, "codex")),
         {:ok, output_path} <- output_path(opts),
         :ok <- ensure_overwrite_allowed(output_path, Keyword.get(opts, :force, false), deps),
         workspace_root <- workspace_root(opts, repo_url),
         repo_path <- normalize_optional(opts, :repo_path),
         workflow <-
           render_workflow(%{
             project_slug: project.slug,
             repo_url: repo_url,
             repo_path: repo_path,
             agent: agent,
             workspace_root: workspace_root
           }),
         :ok <- write_output(output_path, workflow, deps) do
      print_success(deps, output_path)
      :ok
    end
  end

  defp parse_linear_project(opts) do
    case Keyword.get(opts, :linear_project) do
      nil -> {:error, "--linear-project is required\n\n" <> usage_message()}
      value -> LinearProject.parse(value)
    end
  end

  defp require_repo_url(opts) do
    case Keyword.get(opts, :repo_url) do
      nil ->
        {:error, "--repo-url is required\n\n" <> usage_message()}

      "" ->
        {:error, "--repo-url is required\n\n" <> usage_message()}

      value when is_binary(value) ->
        {:ok, String.trim(value)}
    end
  end

  defp validate_agent(value) when value in @valid_agents, do: {:ok, value}

  defp validate_agent(value) do
    {:error, "invalid --agent #{inspect(value)}: expected one of #{Enum.join(@valid_agents, ", ")}"}
  end

  defp output_path(opts) do
    case Keyword.get(opts, :output, "./WORKFLOW.md") do
      "" -> {:error, "--output cannot be empty"}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp ensure_overwrite_allowed(path, force?, deps) do
    cond do
      force? ->
        :ok

      deps.file_exists?.(path) ->
        {:error, "refusing to overwrite existing file at #{path} (pass --force to overwrite)"}

      true ->
        :ok
    end
  end

  defp workspace_root(opts, repo_url) do
    case Keyword.get(opts, :workspace_root) do
      nil -> default_workspace_root(repo_url)
      "" -> default_workspace_root(repo_url)
      value -> value
    end
  end

  defp default_workspace_root(repo_url) do
    Path.join("~/code/symphony-workspaces", repo_basename(repo_url))
  end

  defp repo_basename(repo_url) do
    repo_url
    |> String.trim()
    |> strip_trailing_slash()
    |> Path.basename()
    |> String.replace_suffix(".git", "")
    |> case do
      "" -> "repo"
      base -> base
    end
  end

  defp strip_trailing_slash(value), do: String.replace_trailing(value, "/", "")

  defp normalize_optional(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp write_output(path, workflow, deps) do
    with :ok <- deps.mkdir_p.(Path.dirname(path)),
         :ok <- deps.write.(path, workflow) do
      :ok
    else
      {:error, reason} -> {:error, "failed to write #{path}: #{inspect(reason)}"}
    end
  end

  defp print_success(deps, output_path) do
    deps.puts.("""
    Wrote #{output_path}

    Next steps:
      symphony preflight #{output_path}
      symphony start #{@ack_flag} #{output_path}
    """)
  end

  defp invalid_flags_message(invalid) do
    formatted =
      Enum.map_join(invalid, ", ", fn
        {flag, nil} -> flag
        {flag, value} -> "#{flag}=#{value}"
      end)

    "invalid flags: #{formatted}\n\n" <> usage_message()
  end

  @spec render_workflow(map()) :: String.t()
  def render_workflow(%{
        project_slug: project_slug,
        repo_url: repo_url,
        repo_path: repo_path,
        agent: agent,
        workspace_root: workspace_root
      }) do
    [
      "---",
      "tracker:",
      "  kind: linear",
      "  api_key: $LINEAR_API_KEY",
      "  project_slug: #{yaml_string(project_slug)}",
      "  active_states:",
      "    - Todo",
      "    - In Progress",
      "  terminal_states:",
      "    - Done",
      "    - Closed",
      "    - Canceled",
      "    - Cancelled",
      "    - Duplicate",
      "polling:",
      "  interval_ms: 30000",
      "workspace:",
      "  root: #{yaml_string(workspace_root)}",
      "repo:",
      "  url: #{yaml_string(repo_url)}",
      maybe_repo_path(repo_path),
      "hooks:",
      "  after_create: |",
      "    git clone --depth 1 #{shell_quote(repo_url)} .",
      "agent:",
      "  kind: #{agent}",
      "  max_concurrent_agents: 4",
      "  max_turns: 20",
      agent_block(agent),
      "# The Phoenix dashboard is disabled by default. Enable it by uncommenting",
      "# the block below (or by passing `--port <PORT>` to `symphony start`).",
      "# server:",
      "#   port: 3453",
      "---",
      "",
      prompt_body()
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> ensure_trailing_newline()
  end

  defp maybe_repo_path(nil), do: nil
  defp maybe_repo_path(path), do: "  path: #{yaml_string(path)}"

  defp agent_block("codex") do
    """
      codex:
        # See #{@setup_url} for the full operator setup. The defaults below assume
        # `~/.codex/config.toml` defines a permissions profile that allows
        # unattended `git commit` / `git push` (Approach B in SETUP.md), or that
        # `codex.command` is wrapped with an outer sandbox such as jai (Approach A).
        command: codex app-server
        approval_policy: never
        use_configured_permissions: true
    """
    |> String.trim_trailing("\n")
  end

  defp agent_block("claude") do
    """
      claude:
        # `$SYMPHONY_CLAUDE_PRIV_DIR` is injected by Symphony at sidecar launch
        # time. The Claude Agent SDK's `permission_mode: dontAsk` plus the
        # `allowed_tools` whitelist below is the inner sandbox boundary; jai
        # (#{@setup_url}, Approach A) is an optional outer sandbox.
        command: uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
        permission_mode: dontAsk
        allowed_tools:
          - Read
          - Glob
          - Grep
          - Edit
          - Write
          - MultiEdit
          - Bash
          - BashOutput
          - KillBash
          - TodoWrite
          - NotebookEdit
          - mcp__symphony__linear_graphql
        setting_sources: []
    """
    |> String.trim_trailing("\n")
  end

  defp prompt_body do
    """
    You are working on a Linear ticket `{{ issue.identifier }}`.

    Title: {{ issue.title }}
    URL: {{ issue.url }}
    Status: {{ issue.state }}

    {% if issue.description %}
    Description:
    {{ issue.description }}
    {% else %}
    No description provided.
    {% endif %}

    Operate autonomously end-to-end. Use the `linear_graphql` tool to update the
    issue and post comments. Stop only when blocked by missing required
    permissions or secrets.
    """
    |> String.trim_trailing("\n")
  end

  # Double-quoted YAML scalars interpret `\` as an escape introducer
  # (e.g. `\n`, `\t`), so a literal `\` in the value must become `\\`. Escape
  # backslashes first, then double quotes, so the doubled-up `\\` we just
  # wrote is not re-escaped by the second pass.
  defp yaml_string(value) when is_binary(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  # Use POSIX single-quote escaping (`'foo'\''bar'`) so the value survives
  # shell expansion verbatim — single-quoted strings expand neither `$` nor
  # backticks nor backslashes, so any operator-supplied repo URL is safe even
  # when this `WORKFLOW.md` is later executed by an unattended hook.
  defp shell_quote(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  defp ensure_trailing_newline(value) do
    if String.ends_with?(value, "\n"), do: value, else: value <> "\n"
  end
end
