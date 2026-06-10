defmodule SymphonyElixir.CLI.Preflight do
  @moduledoc """
  Implements `symphony preflight ./WORKFLOW.md` — validates the workflow's
  configuration against the live environment without spawning agents.

  Each check is independent and best-effort: a check that cannot run (e.g.
  `git` not on PATH) is reported but does not short-circuit the rest of the
  run. A non-zero exit is returned when any check fails so CI can gate on it.
  """

  require Logger

  alias SymphonyElixir.CLI.LinearProject
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Linear.Client
  alias SymphonyElixir.Workflow

  # Every check actually returns `{:ok_with_detail, _}` (rendered as `[ok]   <label> — <detail>`),
  # `{:warn, _}`, or `{:error, _}`. The bare `:ok` variant is reserved for a check
  # that wants to render `[ok]   <label>` without a detail line; no current check uses it.
  @type check_result ::
          :ok | {:ok_with_detail, String.t()} | {:warn, String.t()} | {:error, String.t()}
  @type restore_fun :: (-> :ok)
  @type deps :: %{
          set_workflow_file_path: (Path.t() -> :ok),
          system_cmd: (String.t(), [String.t()], keyword() -> {Collectable.t(), non_neg_integer()}),
          system_find_executable: (String.t() -> Path.t() | nil),
          file_exists?: (Path.t() -> boolean()),
          touch_temp: (Path.t() -> :ok | {:error, term()}),
          tcp_listen: (non_neg_integer() -> :ok | {:error, term()}),
          graphql: (String.t(), map() -> {:ok, map()} | {:error, term()}),
          ensure_http_app: (-> :ok),
          silence_logger: (-> restore_fun()),
          program_name: (-> String.t()),
          puts: (IO.chardata() -> :ok),
          puts_err: (IO.chardata() -> :ok)
        }

  @ack_flag "--i-understand-that-this-will-be-running-without-the-usual-guardrails"

  @viewer_query """
  query SymphonyPreflightViewer {
    viewer {
      id
      name
    }
  }
  """

  @project_query """
  query SymphonyPreflightProject($slugId: String!) {
    projects(filter: {slugId: {eq: $slugId}}, first: 1) {
      nodes {
        id
        name
        slugId
      }
    }
  }
  """

  @states_query """
  query SymphonyPreflightStates($slugId: String!) {
    projects(filter: {slugId: {eq: $slugId}}, first: 1) {
      nodes {
        teams(first: 50) {
          nodes {
            states(first: 100) {
              nodes {
                name
                type
              }
            }
          }
        }
      }
    }
  }
  """

  # Linear is Relay-spec compliant, so the connection has no `totalCount`
  # field — counting nodes is the only way to surface a real number here.
  # `first: 250` is Linear's per-page maximum; when more issues exist than fit
  # in one page we display the count with a `+` suffix derived from
  # `pageInfo.hasNextPage`. The earlier `first: 0` form returned an empty
  # `nodes` list and so always rendered "0" / "0+".
  @candidate_page_size 250
  @candidate_count_query """
  query SymphonyPreflightCandidates($slugId: String!, $stateNames: [String!]!) {
    issues(filter: {project: {slugId: {eq: $slugId}}, state: {name: {in: $stateNames}}}, first: #{@candidate_page_size}) {
      pageInfo {
        hasNextPage
      }
      nodes {
        id
      }
    }
  }
  """

  @spec runtime_deps() :: deps()
  def runtime_deps do
    %{
      set_workflow_file_path: &Workflow.set_workflow_file_path/1,
      system_cmd: &System.cmd/3,
      system_find_executable: &System.find_executable/1,
      file_exists?: &File.exists?/1,
      touch_temp: &touch_temp_file/1,
      tcp_listen: &check_tcp_listen/1,
      graphql: &Client.graphql/2,
      # Linear queries go out through `Req`, which needs its `Finch` supervisor
      # up. Preflight runs as a one-shot escript without booting the full
      # orchestrator, so we start just enough of the OTP graph to make HTTP
      # calls. Tests inject a no-op since `graphql` is already mocked.
      ensure_http_app: fn ->
        {:ok, _} = Application.ensure_all_started(:req)
        :ok
      end,
      # Linear.Client logs every non-200 response at :error. Preflight already
      # surfaces those failures inline, so silence the duplicate Logger output
      # for the duration of the run and return a 0-arity restore fn so the
      # global level is reverted before we return — otherwise a preflight that
      # runs in-process with anything else (e.g. tests, or a future `start`
      # subcommand falling through to here) would leave the system at
      # `:critical` forever.
      silence_logger: fn ->
        prev = Logger.level()
        Logger.configure(level: :critical)
        fn -> Logger.configure(level: prev) end
      end,
      program_name: &default_program_name/0,
      puts: fn output -> IO.puts(output) end,
      puts_err: fn output -> IO.puts(:stderr, output) end
    }
  end

  # Returns whichever invocation form the operator used (`./bin/symphony`,
  # `/usr/local/bin/symphony`, or the bare `symphony` if no escript context).
  # Mirroring the invocation form keeps copy-pasted commands working in the
  # exact directory the operator just ran preflight from.
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

  @spec usage_message() :: String.t()
  def usage_message do
    "Usage: symphony preflight [path/to/WORKFLOW.md]"
  end

  # Check-level failures are reported via the `:silent_failure` sentinel —
  # preflight has already rendered the failure rows inline (`render/3`), so
  # `CLI.main/1` translates the sentinel into a non-zero exit without
  # re-printing. String errors are reserved for callsite-level problems like
  # a malformed argv.
  @spec run([String.t()], deps()) :: :ok | {:error, String.t() | :silent_failure}
  def run(args, deps \\ runtime_deps()) do
    case args do
      [] -> with_priming(deps, fn -> do_run(Path.expand("WORKFLOW.md"), deps) end)
      [path] -> with_priming(deps, fn -> do_run(Path.expand(path), deps) end)
      _ -> {:error, usage_message()}
    end
  end

  defp with_priming(deps, work) do
    deps.ensure_http_app.()
    restore = deps.silence_logger.()

    try do
      work.()
    after
      if is_function(restore, 0), do: restore.()
    end
  end

  defp do_run(path, deps) do
    deps.puts.("Running Symphony preflight against #{path}\n")

    case load_settings(path, deps) do
      {:ok, settings} ->
        results = run_checks(settings, deps)
        Enum.each(results, fn {label, result} -> render(label, result, deps) end)
        summary(results, settings, path, deps)

      {:error, reason} ->
        deps.puts_err.("workflow load failed: #{format_error(reason)}")
        {:error, :silent_failure}
    end
  end

  # Load settings straight from the requested file — preflight runs as a
  # one-shot escript so the orchestrator's WorkflowStore is not running.
  # Going through `Workflow.load/1` keeps that contract regardless of whether
  # a different OTP app boot has already cached a workflow elsewhere.
  defp load_settings(path, deps) do
    with {:ok, %{config: config}} <- Workflow.load(path),
         {:ok, settings} <- Schema.parse(config),
         :ok <- deps.set_workflow_file_path.(path) do
      {:ok, settings}
    end
  end

  defp run_checks(settings, deps) do
    [
      {"Linear API key", check_linear_auth(settings, deps)},
      {"Linear project resolution", check_project(settings, deps)},
      {"Linear state coverage", check_states(settings, deps)},
      {"Repo clone access", check_repo_url(settings, deps)},
      {"GitHub credential helper", check_gh_credential(settings, deps)},
      {"Agent availability", check_agent(settings, deps)},
      {"Workspace root writability", check_workspace_root(settings, deps)},
      {"Dashboard port", check_dashboard_port(settings, deps)}
    ]
  end

  defp check_linear_auth(settings, deps) do
    cond do
      settings.tracker.kind != "linear" ->
        {:warn, "tracker.kind is #{inspect(settings.tracker.kind)}; skipping Linear auth check"}

      is_nil(settings.tracker.api_key) ->
        {:error, "LINEAR_API_KEY not set (or tracker.api_key not resolved)"}

      true ->
        case deps.graphql.(@viewer_query, %{}) do
          {:ok, %{"data" => %{"viewer" => %{"id" => _id} = viewer}}} ->
            name = Map.get(viewer, "name") || Map.get(viewer, "id")
            {:ok_with_detail, "authenticated as #{name}"}

          {:ok, body} ->
            {:error, "unexpected viewer response: #{inspect(body)}"}

          {:error, reason} ->
            {:error, "viewer query failed: #{format_error(reason)}"}
        end
    end
  end

  defp check_project(settings, deps) do
    cond do
      settings.tracker.kind != "linear" ->
        {:warn, "tracker.kind is #{inspect(settings.tracker.kind)}; skipping project resolution"}

      is_nil(settings.tracker.project_slug) ->
        {:error, "tracker.project_slug not set"}

      true ->
        case deps.graphql.(@project_query, %{slugId: slug_id_for_query(settings.tracker.project_slug)}) do
          {:ok, %{"data" => %{"projects" => %{"nodes" => [%{"name" => name} | _]}}}} ->
            {:ok_with_detail, "matched #{inspect(name)}"}

          {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}} ->
            {:error, "no Linear project found for slug #{inspect(settings.tracker.project_slug)}"}

          {:ok, body} ->
            {:error, "unexpected project response: #{inspect(body)}"}

          {:error, reason} ->
            {:error, "project query failed: #{format_error(reason)}"}
        end
    end
  end

  # Prefer the 12-hex slug_id form when LinearProject.parse can extract it,
  # falling back to whatever the operator supplied. Linear's slugId filter
  # accepts both forms, but tunnelling everything through the hex form keeps
  # check_project and check_states (and any future Linear query that filters
  # on slugId) consistent.
  defp slug_id_for_query(project_slug) do
    case LinearProject.parse(project_slug) do
      {:ok, %{slug_id: hex}} when is_binary(hex) -> hex
      _ -> project_slug
    end
  end

  defp check_states(settings, deps) do
    cond do
      settings.tracker.kind != "linear" ->
        {:warn, "tracker.kind is #{inspect(settings.tracker.kind)}; skipping state coverage"}

      is_nil(settings.tracker.project_slug) ->
        {:warn, "tracker.project_slug not set; skipping state coverage"}

      true ->
        configured =
          (settings.tracker.active_states ++ settings.tracker.terminal_states)
          |> Enum.uniq()

        case deps.graphql.(@states_query, %{slugId: slug_id_for_query(settings.tracker.project_slug)}) do
          {:ok, %{"data" => %{"projects" => %{"nodes" => [project | _]}}}} ->
            available = collect_state_names(project)
            verify_state_coverage(configured, available)

          {:ok, %{"data" => %{"projects" => %{"nodes" => []}}}} ->
            {:warn, "project not found; skipping state coverage"}

          {:ok, body} ->
            {:error, "unexpected states response: #{inspect(body)}"}

          {:error, reason} ->
            {:error, "states query failed: #{format_error(reason)}"}
        end
    end
  end

  defp collect_state_names(project) do
    project
    |> Map.get("teams", %{})
    |> Map.get("nodes", [])
    |> Enum.flat_map(fn team ->
      team
      |> Map.get("states", %{})
      |> Map.get("nodes", [])
      |> Enum.map(&Map.get(&1, "name"))
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp verify_state_coverage(configured, available) do
    available_set = MapSet.new(available)

    missing =
      configured
      |> Enum.reject(&MapSet.member?(available_set, &1))
      |> Enum.uniq()

    case missing do
      [] -> {:ok_with_detail, "all #{length(configured)} configured states present"}
      _ -> {:error, "missing Linear states: #{Enum.join(missing, ", ")}"}
    end
  end

  defp check_repo_url(settings, deps) do
    case settings.repo.url do
      nil ->
        {:warn, "repo.url not set in WORKFLOW.md — skipping clone-access check (legacy workflows hardcode the URL in hooks.after_create)"}

      url ->
        check_repo_clone_access(url, deps)
    end
  end

  defp check_repo_clone_access(url, deps) do
    case deps.system_find_executable.("git") do
      nil -> {:warn, "git not found on PATH; skipping clone-access check"}
      _ -> run_ls_remote(url, deps)
    end
  end

  defp run_ls_remote(url, deps) do
    case deps.system_cmd.("git", ["ls-remote", "--heads", url], stderr_to_stdout: true) do
      {_output, 0} ->
        {:ok_with_detail, "git ls-remote OK for #{url}"}

      {output, status} ->
        trimmed = output |> to_string() |> String.trim()
        {:error, "git ls-remote exited #{status}: #{trimmed}"}
    end
  end

  # The clone hook authenticates GitHub over HTTPS via git's credential helper,
  # which on Symphony hosts is typically `!gh auth git-credential`. If `gh` is
  # missing from the daemon's PATH the clone dies with a cryptic
  # `gh: not found` / `could not read Username` and `after_create` exits 128 —
  # the daemon then retries on exponential backoff indefinitely. Surface that
  # here as a single clear failure. Gated on a GitHub `repo.url` so we never
  # shell out to git when the URL is absent (legacy hardcoded-hook workflows)
  # or when the remote is SSH-key-only on a non-GitHub host.
  defp check_gh_credential(settings, deps) do
    case settings.repo.url do
      url when is_binary(url) ->
        if github_url?(url) do
          check_gh_for_github(deps)
        else
          {:warn, "repo.url #{inspect(url)} is not a github.com remote; skipping gh credential-helper check"}
        end

      _ ->
        {:warn, "repo.url not set; skipping gh credential-helper check"}
    end
  end

  defp github_url?(url) when is_binary(url), do: String.contains?(url, "github.com")

  defp check_gh_for_github(deps) do
    case github_credential_helper(deps) do
      {:ok, helper} ->
        if String.contains?(helper, "gh") do
          verify_gh_cli(deps)
        else
          {:ok_with_detail, "GitHub uses credential helper #{inspect(helper)} (not gh); skipping gh auth check"}
        end

      :none ->
        {:warn, "no GitHub HTTPS credential helper configured; clones must use an SSH key or another auth method"}
    end
  end

  # `git config --get-urlmatch credential.helper https://github.com` resolves the
  # helper git would actually use for GitHub HTTPS — exactly the value the clone
  # hook relies on. Empty output (or a non-zero exit, which git returns when no
  # value matches) means no HTTPS helper is configured.
  defp github_credential_helper(deps) do
    case deps.system_cmd.(
           "git",
           ["config", "--get-urlmatch", "credential.helper", "https://github.com"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case output |> to_string() |> String.trim() do
          "" -> :none
          helper -> {:ok, helper}
        end

      _ ->
        :none
    end
  end

  defp verify_gh_cli(deps) do
    case deps.system_find_executable.("gh") do
      nil ->
        {:error, "git uses gh as its GitHub credential helper, but gh is not on PATH — clones will fail with exit 128 (gh: not found). Install gh or ensure the daemon's mise PATH includes it."}

      _ ->
        case deps.system_cmd.("gh", ["auth", "status"], stderr_to_stdout: true) do
          {_output, 0} ->
            {:ok_with_detail, "gh authenticated for GitHub"}

          {output, status} ->
            {:error, "gh auth status exited #{status}: #{output |> to_string() |> String.trim()}"}
        end
    end
  end

  defp check_agent(settings, deps) do
    case settings.agent.kind do
      "codex" -> check_agent_command(settings.codex.command, "codex agent", deps)
      "claude" -> check_agent_command(settings.agent.claude.command, "claude sidecar", deps)
      other -> {:warn, "unknown agent.kind #{inspect(other)}; skipping agent check"}
    end
  end

  # The configured `agent.<kind>.command` is what Symphony actually exec()s.
  # Use its first whitespace-separated token as the executable name to verify,
  # so `jai codex ...` checks `jai` (the outer wrapper) rather than `codex`.
  # If the first token is env-backed (`$VAR …`), we can't statically resolve
  # it — emit a warn rather than a false negative.
  defp check_agent_command(command, label, deps) do
    case parse_command_executable(command) do
      {:ok, name} ->
        check_executable(deps, name, label)

      {:env_backed, raw} ->
        {:warn, "#{label}: command starts with env-backed value #{inspect(raw)}; cannot verify availability statically"}

      {:error, :empty} ->
        {:error, "#{label}: agent command is empty"}
    end
  end

  defp parse_command_executable(command) when is_binary(command) do
    case command |> String.trim() |> String.split(~r/\s+/, parts: 2) |> List.first() do
      nil -> {:error, :empty}
      "" -> {:error, :empty}
      "$" <> _ = raw -> {:env_backed, raw}
      name -> {:ok, name}
    end
  end

  defp parse_command_executable(_), do: {:error, :empty}

  defp check_executable(deps, name, label) do
    case deps.system_find_executable.(name) do
      nil -> {:error, "#{label}: #{name} not found on PATH"}
      path -> {:ok_with_detail, "#{label}: found #{name} at #{path}"}
    end
  end

  # Probe writability without materializing anything. If `workspace.root`
  # already exists we touch a temp file inside it; otherwise we walk up to
  # the nearest existing ancestor and probe there — Symphony itself will
  # `mkdir -p` the tree on first issue, so confirming the parent is writable
  # is the right semantic. The earlier implementation called `File.mkdir_p`
  # as part of preflight, silently creating `~/code/symphony-workspaces/...`
  # the first time the operator ran it.
  defp check_workspace_root(settings, deps) do
    root = Path.expand(settings.workspace.root)

    if deps.file_exists?.(root) do
      probe_writable(root, deps, "writable: #{root}")
    else
      case nearest_existing_ancestor(root, deps) do
        nil ->
          {:error, "no existing ancestor of #{root} on disk"}

        ancestor ->
          probe_writable(
            ancestor,
            deps,
            "#{root} will be created under writable ancestor #{ancestor}"
          )
      end
    end
  end

  defp probe_writable(dir, deps, ok_detail) do
    probe = Path.join(dir, ".symphony-preflight-#{System.unique_integer([:positive])}")

    case deps.touch_temp.(probe) do
      :ok -> {:ok_with_detail, ok_detail}
      {:error, reason} -> {:error, "workspace root not writable (#{dir}): #{format_error(reason)}"}
    end
  end

  defp nearest_existing_ancestor(path, deps) do
    parent = Path.dirname(path)

    cond do
      parent == path -> nil
      deps.file_exists?.(parent) -> parent
      true -> nearest_existing_ancestor(parent, deps)
    end
  end

  defp check_dashboard_port(settings, deps) do
    case settings.server.port do
      nil ->
        {:warn, "dashboard disabled (server.port not set); skipping port check"}

      port when is_integer(port) and port >= 0 ->
        evaluate_port(port, deps)

      _ ->
        {:warn, "server.port not an integer; skipping port check"}
    end
  end

  defp evaluate_port(port, deps) do
    case deps.tcp_listen.(port) do
      :ok ->
        label = if port == 0, do: "OS will assign a port", else: "port #{port} is available"
        {:ok_with_detail, label}

      {:error, reason} ->
        {:error, "port #{port} unavailable: #{format_error(reason)}"}
    end
  end

  defp render(label, result, deps) do
    case result do
      :ok -> deps.puts.("  [ok]   #{label}")
      {:ok_with_detail, detail} -> deps.puts.("  [ok]   #{label} — #{detail}")
      {:warn, message} -> deps.puts.("  [warn] #{label}: #{message}")
      {:error, message} -> deps.puts_err.("  [fail] #{label}: #{message}")
    end
  end

  defp summary(results, settings, path, deps) do
    failed = for {label, {:error, _}} <- results, do: label

    print_candidate_count(settings, deps)

    case failed do
      [] ->
        deps.puts.("\nPreflight passed. Start Symphony with:")
        deps.puts.("  #{program_name(deps)} start #{@ack_flag} #{path}")
        :ok

      labels ->
        deps.puts_err.("\nPreflight failed: #{Enum.join(labels, ", ")}")
        {:error, :silent_failure}
    end
  end

  defp print_candidate_count(settings, deps) do
    cond do
      settings.tracker.kind != "linear" ->
        :ok

      is_nil(settings.tracker.project_slug) ->
        :ok

      settings.tracker.active_states == [] ->
        deps.puts.("\nCandidate issues: 0 (no active_states configured)")

      true ->
        fetch_and_print_candidate_count(settings, deps)
    end
  end

  defp fetch_and_print_candidate_count(settings, deps) do
    response =
      deps.graphql.(@candidate_count_query, %{
        slugId: slug_id_for_query(settings.tracker.project_slug),
        stateNames: settings.tracker.active_states
      })

    render_candidate_count(response, deps)
  end

  defp render_candidate_count(
         {:ok, %{"data" => %{"issues" => %{"pageInfo" => page_info, "nodes" => nodes}}}},
         deps
       ) do
    count = length(nodes)
    qualifier = if Map.get(page_info, "hasNextPage"), do: "+", else: ""
    deps.puts.("\nCandidate issues in active states: #{count}#{qualifier}")
  end

  defp render_candidate_count({:ok, body}, deps) do
    deps.puts_err.("\nCandidate issue count unavailable: unexpected response #{inspect(body)}")
  end

  defp render_candidate_count({:error, reason}, deps) do
    deps.puts_err.("\nCandidate issue count unavailable: #{format_error(reason)}")
  end

  defp touch_temp_file(path) do
    with :ok <- File.write(path, "") do
      _ = File.rm(path)
      :ok
    end
  end

  defp check_tcp_listen(port) do
    case :gen_tcp.listen(port, [:binary, {:ip, {127, 0, 0, 1}}, {:reuseaddr, true}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_error(reason) do
    case reason do
      reason when is_binary(reason) -> reason
      atom when is_atom(atom) -> Atom.to_string(atom)
      {:invalid_workflow_config, message} -> "invalid WORKFLOW.md config: #{message}"
      {:missing_workflow_file, path, raw} -> "missing #{path}: #{inspect(raw)}"
      {:workflow_parse_error, raw} -> "parse error: #{inspect(raw)}"
      other -> inspect(other)
    end
  end
end
