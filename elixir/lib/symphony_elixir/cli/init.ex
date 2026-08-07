defmodule SymphonyElixir.CLI.Init do
  @moduledoc """
  Implements `symphony init` — generates a usable `WORKFLOW.md` (and optionally
  a per-instance `Makefile`) from a Linear project URL/slug and a repo clone URL.
  """

  alias SymphonyElixir.CLI.LinearProject
  alias SymphonyElixir.Config.Schema

  @switches [
    linear_project: :string,
    repo_url: :string,
    repo_path: :string,
    workspace_root: :string,
    agent: :string,
    base_branch: :string,
    output: :string,
    force: :boolean,
    port: :integer,
    host: :string,
    instance_makefile: :string,
    instance_name: :string
  ]

  @aliases [o: :output, f: :force]

  @valid_agents Schema.Agent.kinds()
  @setup_url "https://github.com/Identione/symphony/blob/main/SETUP.md"

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  @instance_name_regex ~r/^[A-Za-z0-9_.-]+$/

  @type template_name :: :workflow | :instance_makefile

  @type deps :: %{
          file_exists?: (Path.t() -> boolean()),
          write: (Path.t(), iodata() -> :ok | {:error, term()}),
          mkdir_p: (Path.t() -> :ok | {:error, term()}),
          program_name: (-> String.t()),
          puts: (IO.chardata() -> :ok),
          read_template: (template_name() -> {:ok, String.t()} | {:error, term()})
        }

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      file_exists?: &File.exists?/1,
      write: &File.write/2,
      mkdir_p: &File.mkdir_p/1,
      program_name: &default_program_name/0,
      puts: fn output -> IO.puts(output) end,
      read_template: &default_read_template/1
    }
  end

  # Mirror whichever invocation form the operator used (`./bin/symphony`,
  # absolute path, or bare `symphony` if not running as an escript) so the
  # printed next-step commands can be copy-pasted from the same shell.
  defp default_program_name do
    case :escript.script_name() do
      [] -> "symphony"
      name when is_list(name) -> to_string(name)
    end
  rescue
    _ -> "symphony"
  end

  defp program_name(%{program_name: fun}) when is_function(fun, 0), do: fun.()
  defp program_name(_deps), do: "symphony"

  # `mix.exs` sets `app: nil` on the escript, so `:symphony_elixir` is not
  # auto-started at escript runtime — `Application.app_dir/2` only resolves
  # the right path at mix/test time. `:escript.script_name/0` returns the
  # mix wrapper path under `mix test`, so we can't just key on it being
  # empty. Try both candidate paths and use whichever exists.
  defp default_read_template(name) do
    relative = template_relative_path(name)

    [
      try_app_dir(relative),
      script_relative_path(relative)
    ]
    |> Enum.reject(&is_nil/1)
    |> read_first_existing()
  end

  defp try_app_dir(relative) do
    Application.app_dir(:symphony_elixir, relative)
  rescue
    ArgumentError -> nil
  end

  defp script_relative_path(relative) do
    case :escript.script_name() do
      [] ->
        nil

      script ->
        script
        |> to_string()
        |> Path.expand()
        |> Path.dirname()
        |> Path.join("../#{relative}")
        |> Path.expand()
    end
  end

  defp read_first_existing([]), do: {:error, :enoent}

  defp read_first_existing([path | rest]) do
    case File.read(path) do
      {:ok, _} = ok -> ok
      _ -> read_first_existing(rest)
    end
  end

  defp template_relative_path(:workflow), do: "priv/templates/workflow.md.eex"
  defp template_relative_path(:instance_makefile), do: "priv/templates/instance.Makefile.eex"

  @spec usage_message() :: String.t()
  def usage_message do
    """
    Usage: symphony init \\
      --linear-project <URL_OR_SLUG> \\
      --repo-url <CLONE_URL> \\
      [--workspace-root <PATH>] \\
      [--repo-path <LOCAL_PATH>] \\
      [--agent codex|claude] \\
      [--base-branch <NAME>] \\
      [--output <PATH>] \\
      [--port <PORT>] \\
      [--host <ADDR>] \\
      [--instance-makefile <PATH>] \\
      [--instance-name <NAME>] \\
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
      --base-branch      Branch agents work from instead of the repo default.
                         When set, generated instances isolate work onto per-issue
                         branches off origin/<NAME>, target <NAME> for the PR, and
                         refuse pushing protected branches (leaving the default
                         branch untouched). Validated as a safe git branch name.
                         Omit to keep today's behavior (PRs target the repo default).
      --output           Output path for the generated workflow. Defaults to
                         ./WORKFLOW.md.
      --port             Enable the Phoenix dashboard on the given port.
                         Non-negative integer. 0 means OS-assigned. When omitted,
                         no `server:` block is emitted.
      --host             Bind address for the dashboard. IPv4 or IPv6 literal.
                         Defaults to 127.0.0.1 (loopback). Set to 0.0.0.0 to
                         listen on all interfaces. Requires --port.
      --instance-makefile Path for the optional per-instance Makefile. When
                         given, --instance-name is required and both outputs
                         are gated together by --force.
      --instance-name    Slug for the instance Makefile (path-safe:
                         A-Za-z0-9_.- only; no leading dot, no '..').
      --force            Overwrite existing output file(s).
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
    force? = Keyword.get(opts, :force, false)

    with {:ok, project} <- parse_linear_project(opts),
         {:ok, repo_url} <- require_repo_url(opts),
         {:ok, agent} <- validate_agent(Keyword.get(opts, :agent, "codex")),
         {:ok, base_branch} <- validate_base_branch(Keyword.get(opts, :base_branch)),
         {:ok, port} <- validate_port(Keyword.get(opts, :port)),
         {:ok, host} <- validate_host(Keyword.get(opts, :host), port),
         {:ok, instance} <- resolve_instance(opts),
         {:ok, output_path} <- output_path(opts),
         :ok <- ensure_overwrite_allowed(output_path, force?, deps),
         :ok <- ensure_instance_overwrite_allowed(instance, force?, deps),
         workspace_root <- workspace_root(opts, repo_url),
         repo_path <- normalize_optional(opts, :repo_path),
         {:ok, workflow_template} <- deps.read_template.(:workflow),
         {:ok, instance_template} <- maybe_read_instance_template(instance, deps),
         workflow <-
           render_workflow_with_template(workflow_template, %{
             project_slug: project.slug,
             repo_url: repo_url,
             repo_path: repo_path,
             agent: agent,
             workspace_root: workspace_root,
             base_branch: base_branch,
             port: port,
             host: host
           }),
         instance_makefile_content <-
           render_instance_makefile(instance_template, instance),
         :ok <- write_output(output_path, workflow, deps),
         :ok <- maybe_write_instance(instance, instance_makefile_content, deps) do
      print_success(deps, output_path, instance, base_branch)
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

  # Absent flag → nil: no base-aware machinery is emitted and the generated
  # workflow behaves exactly as today (PRs target the repo's own default
  # branch). When present, validate with a regex stricter than
  # `git check-ref-format` so the value is also shell/YAML-safe: only
  # `[A-Za-z0-9._/-]`, no leading `-`, no `..`/`@{`, no trailing `/` or
  # `.lock`. This rejects every shell metacharacter (`$;&|`"' `, backticks…)
  # that a merely ref-legal name could otherwise carry into the clone hook.
  @base_branch_regex ~r{\A[A-Za-z0-9._/-]+\z}

  defp validate_base_branch(nil), do: {:ok, nil}

  defp validate_base_branch(value) when is_binary(value) do
    cond do
      not Regex.match?(@base_branch_regex, value) ->
        {:error, base_branch_error(value)}

      String.starts_with?(value, "-") ->
        {:error, base_branch_error(value)}

      String.contains?(value, "..") or String.contains?(value, "@{") ->
        {:error, base_branch_error(value)}

      String.ends_with?(value, "/") or String.ends_with?(value, ".lock") ->
        {:error, base_branch_error(value)}

      true ->
        {:ok, value}
    end
  end

  defp base_branch_error(value) do
    "--base-branch must be a valid git branch name using only letters, digits, " <>
      "`.`, `_`, `/`, `-` (got: #{inspect(value)})\n\n" <> usage_message()
  end

  defp validate_port(nil), do: {:ok, nil}
  defp validate_port(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp validate_port(value) do
    {:error, "--port must be a non-negative integer (got: #{inspect(value)})\n\n" <> usage_message()}
  end

  defp validate_host(nil, _port), do: {:ok, nil}

  defp validate_host("", _port) do
    {:error, "--host requires a non-empty IPv4 or IPv6 address\n\n" <> usage_message()}
  end

  defp validate_host(value, nil) when is_binary(value) do
    {:error,
     "--host requires --port (the server block needs both port and host)\n\n" <>
       usage_message()}
  end

  defp validate_host(value, _port) when is_binary(value) do
    case :inet.parse_strict_address(String.to_charlist(value)) do
      {:ok, _ip} ->
        {:ok, value}

      {:error, :einval} ->
        {:error,
         "--host must be a literal IPv4 or IPv6 address (got: #{inspect(value)})\n\n" <>
           usage_message()}
    end
  end

  defp resolve_instance(opts) do
    case {Keyword.get(opts, :instance_makefile), Keyword.get(opts, :instance_name)} do
      {nil, nil} ->
        {:ok, nil}

      {nil, _name} ->
        {:error, "--instance-name requires --instance-makefile\n\n" <> usage_message()}

      {_path, nil} ->
        {:error, "--instance-makefile requires --instance-name\n\n" <> usage_message()}

      {path, name} ->
        with {:ok, validated_name} <- validate_instance_name(name) do
          expanded = Path.expand(path)

          {:ok,
           %{
             makefile_path: expanded,
             instance_dir: Path.dirname(expanded),
             instance_name: validated_name,
             root: derive_repo_root()
           }}
        end
    end
  end

  defp validate_instance_name(""),
    do: {:error, "--instance-name must be a non-empty string\n\n" <> usage_message()}

  defp validate_instance_name(value) when is_binary(value) do
    cond do
      not Regex.match?(@instance_name_regex, value) ->
        {:error,
         "--instance-name contains invalid characters (allowed: A-Z a-z 0-9 _ . -; got: #{inspect(value)})\n\n" <>
           usage_message()}

      String.starts_with?(value, ".") ->
        {:error,
         "--instance-name must not start with '.' (got: #{inspect(value)})\n\n" <>
           usage_message()}

      String.contains?(value, "..") ->
        {:error,
         "--instance-name must not contain '..' (got: #{inspect(value)})\n\n" <>
           usage_message()}

      true ->
        {:ok, value}
    end
  end

  # Derive the repo root: <repo>/elixir/bin/symphony → <repo>.
  # In escript mode the script name is the launched path; in mix/test we
  # rely on cwd, which is `<repo>/elixir` for our quality gate.
  defp derive_repo_root do
    case :escript.script_name() do
      [] ->
        cwd = File.cwd!() |> Path.expand()

        if Path.basename(cwd) == "elixir" do
          Path.dirname(cwd)
        else
          cwd
        end

      script ->
        script
        |> to_string()
        |> Path.expand()
        |> Path.dirname()
        |> Path.dirname()
        |> Path.dirname()
    end
  rescue
    _ -> File.cwd!()
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

  defp ensure_instance_overwrite_allowed(nil, _force?, _deps), do: :ok

  defp ensure_instance_overwrite_allowed(%{makefile_path: path}, force?, deps),
    do: ensure_overwrite_allowed(path, force?, deps)

  defp maybe_read_instance_template(nil, _deps), do: {:ok, nil}
  defp maybe_read_instance_template(_instance, deps), do: deps.read_template.(:instance_makefile)

  defp maybe_write_instance(nil, _content, _deps), do: :ok

  defp maybe_write_instance(%{makefile_path: path}, content, deps),
    do: write_output(path, content, deps)

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

  # SCP-form URLs (`git@host:org/repo.git`, `git@host:repo.git`) and HTTPS
  # URLs (`https://host/org/repo.git`) both end in the repo name, but split on
  # different separators. Path.basename only splits on `/`, so `git@host:repo`
  # would surface the whole `git@host:repo` as the basename. Taking the last
  # segment after either `/` or `:` reduces both forms to the bare repo name.
  defp repo_basename(repo_url) do
    repo_url
    |> String.trim()
    |> strip_trailing_separators()
    |> String.split(["/", ":"])
    |> List.last()
    |> String.replace_suffix(".git", "")
    |> case do
      "" -> "repo"
      base -> base
    end
  end

  defp strip_trailing_separators(value) do
    value
    |> String.replace_trailing("/", "")
    |> String.replace_trailing(":", "")
  end

  defp normalize_optional(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp write_output(path, content, deps) do
    with :ok <- deps.mkdir_p.(Path.dirname(path)),
         :ok <- deps.write.(path, content) do
      :ok
    else
      {:error, reason} -> {:error, "failed to write #{path}: #{inspect(reason)}"}
    end
  end

  defp print_success(deps, output_path, instance, base_branch) do
    program = program_name(deps)

    base = """
    Wrote #{output_path}

    Next steps:
      #{program} preflight #{output_path}
      #{program} start #{@ack_flag} #{output_path}
    """

    extra =
      case instance do
        nil ->
          ""

        %{makefile_path: makefile_path, instance_dir: instance_dir} ->
          """

          Instance Makefile: #{makefile_path}
          Run from the instance:
            cd #{instance_dir}
            make preflight
            make start
          """
      end

    deps.puts.(base <> extra <> skills_reminder(base_branch))
  end

  # The generated prompt references repo-local skills (commit/push/pull/land/…).
  # They resolve from the cloned target repo's `.codex/skills/`, which Symphony
  # never vendors — so remind the operator to provision them. When a base branch
  # is set, the base-aware behavior lives in those skills (read back via
  # `git config symphony.baseBranch`), so the copied skills must be current.
  defp skills_reminder(nil) do
    """

    The cloned repo must carry repo-local skills (.codex/skills/) for the
    workflow's commit/push/pull/land steps; copy them from the Symphony repo
    if absent.
    """
  end

  defp skills_reminder(base_branch) do
    skills_reminder(nil) <>
      """
      Base branch '#{base_branch}': the base-aware behavior (PR --base, branching
      off origin/#{base_branch}, the protected-branch guard) lives in those skills
      and reads `git config symphony.baseBranch` — copy the base-aware versions.
      """
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
  def render_workflow(params) do
    case default_read_template(:workflow) do
      {:ok, template} -> render_workflow_with_template(template, params)
      {:error, reason} -> raise "failed to read workflow template: #{inspect(reason)}"
    end
  end

  defp render_workflow_with_template(template, params) do
    assigns = build_workflow_assigns(params)

    template
    |> EEx.eval_string(assigns: assigns)
    |> ensure_trailing_newline()
  end

  defp build_workflow_assigns(
         %{
           project_slug: project_slug,
           repo_url: repo_url,
           repo_path: repo_path,
           agent: agent,
           workspace_root: workspace_root
         } = params
       ) do
    port = Map.get(params, :port)
    host = Map.get(params, :host)
    # Read via Map.get (NOT the function head): the public `render_workflow/1` is
    # exercised by tests that pass maps without `:base_branch`, so destructuring
    # it in the head would raise MatchError. nil → renders today's `origin/main`.
    base_branch = Map.get(params, :base_branch)

    [
      project_slug: yaml_string(project_slug),
      workspace_root: yaml_string(workspace_root),
      repo_url: yaml_string(repo_url),
      repo_path_line: render_repo_path_line(repo_path),
      repo_url_shell: shell_quote(repo_url),
      agent_kind: agent,
      agent_block: both_agent_blocks(),
      server_block: render_server_block(port, host),
      # `base_branch` is nil unless `--base-branch` was given. The template uses
      # `@base_branch || "main"` for the inline `origin/<base>` refs (so nil
      # renders today's `origin/main`) and gates the issue-branch section / clone
      # hook on `@base_branch` being truthy.
      base_branch: base_branch,
      repo_base_branch_line: render_repo_base_branch_line(base_branch),
      base_fetch_refspec: base_branch && shell_quote("#{base_branch}:refs/remotes/origin/#{base_branch}"),
      base_branch_shell: base_branch && shell_quote(base_branch)
    ]
  end

  # Always render both `agent.claude:` and `agent.codex:` blocks side by side.
  # `agent.kind` (driven by `--agent`) is what selects which adapter runs;
  # keeping both blocks present makes switching adapters a one-line edit, the
  # same pattern the maintainer's elixir/WORKFLOW.md uses.
  defp both_agent_blocks do
    agent_block("claude") <> "\n" <> agent_block("codex")
  end

  defp render_repo_path_line(nil), do: ""
  defp render_repo_path_line(path), do: "  path: #{yaml_string(path)}\n"

  # Mirrors render_repo_path_line/1: nil → no line (front matter byte-identical
  # to today), otherwise a `base_branch:` line nested under `repo:`. A line
  # assign (rather than an inline `<%= if %>` in the template) keeps the YAML
  # indentation correct and avoids EEx-conditional whitespace artifacts. The
  # set case also emits a reminder comment: base_branch needs base-aware skills
  # provisioned in the target repo (Symphony never vendors them).
  defp render_repo_base_branch_line(nil), do: ""

  defp render_repo_base_branch_line(base) do
    "  # base_branch needs base-aware push/pull/land skills (incl. land_watch.py,\n" <>
      "  # read `git config symphony.baseBranch`) provisioned in the target repo —\n" <>
      "  # Symphony does not vendor them. See SPEC.md §5.3.6 + elixir/README.md.\n" <>
      "  base_branch: #{yaml_string(base)}\n"
  end

  defp render_server_block(nil, _host), do: ""

  defp render_server_block(port, nil) when is_integer(port) do
    "server:\n  port: #{port}\n"
  end

  defp render_server_block(port, host) when is_integer(port) and is_binary(host) do
    "server:\n  port: #{port}\n  host: #{yaml_string(host)}\n"
  end

  defp render_instance_makefile(nil, nil), do: ""

  defp render_instance_makefile(template, %{
         root: root,
         instance_dir: instance_dir,
         instance_name: instance_name
       }) do
    EEx.eval_string(template,
      assigns: [
        root: root,
        instance_dir: instance_dir,
        instance_name: instance_name
      ]
    )
  end

  defp agent_block("codex") do
    """
      codex:
        # command: pick ONE. SPEC.md §5.3.5.1 + #{@setup_url}.
        # (A) jai outer sandbox; Codex's own sandbox disabled at the CLI (Linux kernel >= 6.13):
        #command: jai codex --config sandbox_mode=danger-full-access app-server
        # (B) host codex with a ~/.codex/config.toml permissions profile (portable default):
        command: codex app-server
        approval_policy: never
        use_configured_permissions: true
    """
    |> String.trim_trailing("\n")
  end

  defp agent_block("claude") do
    """
      claude:
        # command: pick ONE. $SYMPHONY_CLAUDE_PRIV_DIR is injected by Claude.AppServer
        # at sidecar launch. SPEC.md §5.3.5.2 + #{@setup_url}.
        # (A) jai outer sandbox (Linux kernel >= 6.13). `--dir $SYMPHONY_CLAUDE_PRIV_DIR`
        # is required: jai casual mode overlays $HOME copy-on-write and only the cwd
        # (the workspace) is live; the orchestrator repo otherwise reads from the COW
        # overlay, which serves a STALE sidecar once uv/python write into priv (copy-up)
        # and sync_workpad disappears. `--dir` grants the priv dir as a live bind that
        # bypasses the overlay; cwd stays the workspace so the agent's workpad writes
        # reach real disk for Symphony's File.read. `--dir $HOME/.cargo` +
        # `--dir $HOME/.rustup` likewise take the Rust toolchain out of the overlay
        # (overlay readdir returns empty on lower-layer registry dirs → lalrpop/NIF
        # build fails). The (B) non-jai variant has no overlay and needs no `--dir`.
        #command: jai --dir $SYMPHONY_CLAUDE_PRIV_DIR --dir $HOME/.cargo --dir $HOME/.rustup uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
        # (B) no outer sandbox; the Claude SDK is the only boundary (portable default):
        command: uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
        # Per-issue-state overrides, keyed by Linear state name (case-insensitive;
        # an entry wins over the top-level model/effort). Mechanical Merging/land
        # runs don't need the flagship at effort high.
        # model_by_state:
        #   Merging: claude-sonnet-5
        # effort_by_state:
        #   Merging: low
        #   Rework: medium
        # permission_mode: bypassPermissions (active) = allow-all under the jai +
        # workspace-cwd boundary; dontAsk = deny anything not in allowed_tools (an
        # empty/absent allowed_tools is then rejected at boot). SPEC.md §5.3.5.2.
        permission_mode: bypassPermissions
        # allowed_tools (ignored under bypassPermissions; the dontAsk whitelist —
        # full filesystem + shell, no WebFetch/WebSearch). Note that `Task`/`Agent`
        # is NOT gated by this list — subagent calls are permitted under `dontAsk`
        # whether or not it appears here, so do not add it expecting a behavior
        # change, and do not remove anything expecting to disable delegation.
        # Subagents are kept inside the turn by the sidecar's forced
        # CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1, not by permissions):
        #allowed_tools:
        #  - Read
        #  - Glob
        #  - Grep
        #  - Edit
        #  - Write
        #  - MultiEdit
        #  - Bash
        #  - BashOutput
        #  - KillBash
        #  - TodoWrite
        #  - NotebookEdit
        #  - mcp__symphony__linear_graphql        # in-process Linear tool (auth stays in Symphony)
        #  - mcp__symphony_workpad__sync_workpad  # in-process workpad sync (its own sdk MCP server)
        #  #- mcp__lsp                        # project .mcp.json servers need mcp__<server> here
        # Hard-deny list (enforced under both permission modes). The harness's
        # task-management/monitor tools misfire in unattended runs — deny them.
        # disallowed_tools:
        #   - Monitor
        #   - TaskCreate
        #   - TaskUpdate
        #   - TaskList
        #   - TaskGet
        #   - TaskStop
        #   - TaskOutput
        #   - SendMessage
        # setting_sources unset → loads the target repo's .claude/settings.json,
        # .mcp.json servers, and CLAUDE.md (contained by jai). Set [] to isolate.
        #setting_sources: []
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

  # POSIX-safe single-quote wrapping: close, escape the apostrophe, reopen.
  defp shell_quote(value) when is_binary(value) do
    escaped = String.replace(value, "'", "'\\''")
    "'" <> escaped <> "'"
  end

  defp ensure_trailing_newline(content) do
    if String.ends_with?(content, "\n"), do: content, else: content <> "\n"
  end
end
