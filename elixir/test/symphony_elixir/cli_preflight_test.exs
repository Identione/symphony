defmodule SymphonyElixir.CLI.PreflightTest do
  use SymphonyElixir.TestSupport

  require Logger

  alias SymphonyElixir.CLI.Preflight

  defp build_deps(overrides) do
    parent = self()

    %{
      set_workflow_file_path: fn path ->
        send(parent, {:set_workflow_file_path, path})
        :ok
      end,
      system_cmd: fn cmd, args, _opts ->
        send(parent, {:system_cmd, cmd, args})
        Map.get(Map.get(overrides, :system_cmd, %{}), {cmd, args}, {"", 0})
      end,
      system_find_executable: fn name ->
        case Map.get(overrides, :find_executable) do
          %{} = m -> Map.get(m, name)
          _ -> Path.join("/usr/bin", name)
        end
      end,
      file_exists?: Map.get(overrides, :file_exists?, fn _path -> true end),
      touch_temp: Map.get(overrides, :touch_temp, fn _path -> :ok end),
      tcp_listen: fn _port -> Map.get(overrides, :tcp_listen, :ok) end,
      graphql: fn query, vars ->
        send(parent, {:graphql, query, vars})
        responses = Map.get(overrides, :graphql, %{})
        find_response(responses, query)
      end,
      # No-ops in tests: graphql is mocked, so we don't need the Req app, and
      # mutating the global Logger level here would leak into other suites.
      # silence_logger returns a 0-arity restore fn (see Preflight.deps) — the
      # no-op restores nothing.
      ensure_http_app: fn -> :ok end,
      silence_logger: fn -> fn -> :ok end end,
      program_name: Map.get(overrides, :program_name, fn -> "symphony" end),
      puts: fn output ->
        send(parent, {:puts, IO.iodata_to_binary(output)})
        :ok
      end,
      puts_err: fn output ->
        send(parent, {:puts_err, IO.iodata_to_binary(output)})
        :ok
      end
    }
  end

  defp find_response(responses, query) do
    Enum.find_value(responses, {:error, :no_match}, fn {pattern, response} ->
      cond do
        is_binary(pattern) and pattern == query -> response
        is_binary(pattern) and String.contains?(query, pattern) -> response
        true -> nil
      end
    end)
  end

  defp graphql_responses(slug, candidate_count, overrides \\ []) do
    overrides = Map.new(overrides)

    %{
      "viewer" =>
        Map.get(
          overrides,
          :viewer,
          {:ok, %{"data" => %{"viewer" => %{"id" => "vid", "name" => "Tester"}}}}
        ),
      "projects(filter: {slugId" =>
        Map.get(
          overrides,
          :project,
          {:ok,
           %{
             "data" => %{
               "projects" => %{
                 "nodes" => [
                   %{
                     "id" => "p",
                     "name" => "Symphony",
                     "slugId" => slug,
                     "teams" => %{
                       "nodes" => [
                         %{
                           "states" => %{
                             "nodes" => [
                               %{"name" => "Todo", "type" => "unstarted"},
                               %{"name" => "In Progress", "type" => "started"},
                               %{"name" => "Done", "type" => "completed"},
                               %{"name" => "Closed", "type" => "canceled"},
                               %{"name" => "Canceled", "type" => "canceled"},
                               %{"name" => "Cancelled", "type" => "canceled"},
                               %{"name" => "Duplicate", "type" => "canceled"}
                             ]
                           }
                         }
                       ]
                     }
                   }
                 ]
               }
             }
           }}
        ),
      "issues(filter:" =>
        Map.get(
          overrides,
          :issues,
          {:ok,
           %{
             "data" => %{
               "issues" => %{
                 "pageInfo" => %{"hasNextPage" => false},
                 "nodes" =>
                   if(candidate_count > 0,
                     do: for(i <- 1..candidate_count, do: %{"id" => Integer.to_string(i)}),
                     else: []
                   )
               }
             }
           }}
        )
    }
  end

  defp tmp_workflow!(name, opts) do
    workflow_root = Path.join(System.tmp_dir!(), "preflight-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    write_workflow_file!(workflow_file, opts)
    on_exit(fn -> File.rm_rf(workflow_root) end)
    workflow_file
  end

  test "Usage error for too many positional args" do
    assert {:error, message} = Preflight.run(["a", "b"], build_deps(%{}))
    assert message =~ "Usage: symphony preflight"
  end

  test "fails fast when WORKFLOW.md cannot be parsed" do
    deps = build_deps(%{})
    bogus = Path.join(System.tmp_dir!(), "no-such-workflow-#{System.unique_integer([:positive])}.md")

    assert {:error, :silent_failure} = Preflight.run([bogus], deps)
  end

  test "does not materialize workspace.root as a side effect (regression: preflight used to mkdir_p)" do
    project_slug = "symphony-2e32f5d86d8c"

    tmp_ancestor = Path.join(System.tmp_dir!(), "preflight-ws-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_ancestor)
    on_exit(fn -> File.rm_rf(tmp_ancestor) end)

    workspace_root = Path.join([tmp_ancestor, "nested", "leaf"])
    refute File.exists?(workspace_root)

    workflow_file =
      tmp_workflow!("ws-no-mkdir",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        workspace_root: workspace_root,
        server_port: nil
      )

    parent = self()

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        # Use the real filesystem so the absence of `workspace_root` actually
        # forces the ancestor-walk path.
        file_exists?: &File.exists?/1,
        touch_temp: fn path ->
          send(parent, {:touch_temp, path})
          :ok
        end
      })

    assert :ok = Preflight.run([workflow_file], deps)

    # Preflight must NOT have created the workspace tree.
    refute File.exists?(workspace_root)

    # The probe must have landed on the nearest existing ancestor (`tmp_ancestor`),
    # not on the never-created `workspace_root` itself.
    assert_received {:touch_temp, probe_path}
    assert Path.dirname(probe_path) == tmp_ancestor

    msgs = collect_puts()
    full = Enum.join(msgs, "\n")
    assert full =~ "[ok]   Workspace root writability"
    assert full =~ "will be created under writable ancestor #{tmp_ancestor}"
  end

  test "restores Logger level after the run (regression: silence_logger was permanent)" do
    project_slug = "symphony-2e32f5d86d8c"

    workflow_file =
      tmp_workflow!("logger-restore",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        server_port: nil
      )

    original_level = Logger.level()
    on_exit(fn -> Logger.configure(level: original_level) end)
    Logger.configure(level: :warning)

    # Use the real silence_logger from runtime_deps so we exercise the actual
    # save/restore path. Other I/O remains mocked.
    real_silence = Preflight.runtime_deps().silence_logger

    deps =
      build_deps(%{graphql: graphql_responses(project_slug, 0)})
      |> Map.put(:silence_logger, real_silence)

    assert :ok = Preflight.run([workflow_file], deps)

    assert Logger.level() == :warning,
           "Logger level leaked past preflight: expected :warning, got #{inspect(Logger.level())}"
  end

  test "check_states sends the 12-hex slug_id (not the full URL slug) like check_project" do
    # Regression: check_project unwrapped `symphony-2e32f5d86d8c` to its trailing
    # `2e32f5d86d8c` slug_id via LinearProject.parse, but check_states passed the
    # raw `symphony-2e32f5d86d8c` straight into the @states_query variables.
    # Linear's slugId filter accepts both forms, but the inconsistency reads
    # like a bug. Both checks must agree on which form they send.
    project_slug = "symphony-2e32f5d86d8c"

    workflow_file =
      tmp_workflow!("states-slug-id",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        server_port: nil
      )

    deps = build_deps(%{graphql: graphql_responses(project_slug, 0)})

    assert :ok = Preflight.run([workflow_file], deps)

    # Collect every (query, vars) pair the test mock saw. Project + states must
    # have used the unwrapped 12-hex slug_id form (not the URL slug).
    pairs =
      collect_graphql_pairs()
      |> Enum.filter(fn {query, _vars} -> String.contains?(query, "projects(filter: {slugId") end)

    assert length(pairs) >= 2,
           "expected at least project + states queries; got #{length(pairs)}: #{inspect(pairs)}"

    Enum.each(pairs, fn {_query, vars} ->
      assert Map.get(vars, :slugId) == "2e32f5d86d8c",
             "expected slugId=2e32f5d86d8c (12-hex form), got #{inspect(vars)}"
    end)
  end

  test "candidate count query asks Linear for a real page size (regression: was first: 0)" do
    project_slug = "symphony-2e32f5d86d8c"

    workflow_file =
      tmp_workflow!("count-page-size",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        server_port: nil
      )

    deps = build_deps(%{graphql: graphql_responses(project_slug, 0)})

    assert :ok = Preflight.run([workflow_file], deps)

    # The candidate-count query previously asked Linear for `first: 0`. Linear is
    # Relay-spec compliant, so `first: 0` returns an empty `nodes` list — the
    # rendered count was therefore always "0" or "0+" regardless of how many
    # issues actually matched. Unit-test mocks here returned nodes anyway, so the
    # bug was invisible without an integration test; pin the page-size in the
    # query string directly instead.
    candidate_query =
      collect_graphql_queries()
      |> Enum.find(&String.contains?(&1, "issues(filter:"))

    assert is_binary(candidate_query), "preflight never issued the candidate-count query"
    refute candidate_query =~ "first: 0"
    assert candidate_query =~ ~r/first:\s*[1-9]\d+/
  end

  test "happy path: all checks pass and prints candidate count" do
    project_slug = "symphony-2e32f5d86d8c"
    repo_url = "git@github.com:org/repo.git"

    workflow_file =
      tmp_workflow!("success",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        repo_url: repo_url,
        server_port: 0
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 2),
        program_name: fn -> "./bin/symphony" end
      })

    assert :ok = Preflight.run([workflow_file], deps)

    msgs = collect_puts()
    full = Enum.join(msgs, "\n")

    assert full =~ "[ok]   Linear API key"
    assert full =~ "[ok]   Linear project resolution"
    assert full =~ "[ok]   Linear state coverage"
    assert full =~ "[ok]   Repo clone access"
    assert full =~ "[ok]   Agent availability"
    assert full =~ "[ok]   Workspace root writability"
    assert full =~ "[ok]   Dashboard port"
    assert full =~ "Candidate issues in active states: 2"

    # Regression: the success line used to read Workflow.workflow_file_path() from
    # global state. do_run already knows the expanded path it just probed, so the
    # message must include the same expanded path verbatim — no reach-around to
    # globally-set state — to keep preflight testable in isolation. The program
    # name is also pulled from deps so a locally-built escript can echo the
    # invocation form the operator just used (./bin/symphony) instead of an
    # un-installed `symphony`.
    assert full =~
             "./bin/symphony start --i-understand-that-this-will-be-running-without-the-usual-guardrails #{Path.expand(workflow_file)}"
  end

  test "reports missing LINEAR_API_KEY as a hard failure" do
    workflow_file =
      tmp_workflow!("no-key",
        tracker_api_token: "$LINEAR_API_KEY",
        server_port: nil
      )

    original = System.get_env("LINEAR_API_KEY")
    System.delete_env("LINEAR_API_KEY")
    on_exit(fn -> restore_env("LINEAR_API_KEY", original) end)

    deps = build_deps(%{})

    assert {:error, :silent_failure} = Preflight.run([workflow_file], deps)

    fails = collect_puts_err()
    assert Enum.any?(fails, &String.contains?(&1, "Linear API key"))
    assert Enum.any?(fails, &String.contains?(&1, "LINEAR_API_KEY not set"))
  end

  test "reports an inaccessible repo URL as a failure when git is on PATH" do
    project_slug = "symphony-2e32f5d86d8c"
    repo_url = "git@example.invalid:org/repo.git"

    workflow_file =
      tmp_workflow!("repo",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        repo_url: repo_url,
        server_port: nil
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        system_cmd: %{
          {"git", ["ls-remote", "--heads", repo_url]} => {"fatal: Could not resolve hostname", 128}
        },
        find_executable: %{"git" => "/usr/bin/git", "codex" => "/usr/bin/codex"}
      })

    assert {:error, :silent_failure} = Preflight.run([workflow_file], deps)

    fails = collect_puts_err()
    assert Enum.any?(fails, &String.contains?(&1, "Repo clone access"))
    assert Enum.any?(fails, &String.contains?(&1, "Could not resolve hostname"))
  end

  test "reports unavailable agent and unwritable workspace and busy port" do
    project_slug = "symphony-2e32f5d86d8c"

    workflow_file =
      tmp_workflow!("bad",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        server_port: 65_001
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        find_executable: %{"git" => "/usr/bin/git"},
        tcp_listen: {:error, :eaddrinuse},
        # Existing root, but the probe write fails — same surface as a
        # permission-denied workspace.
        file_exists?: fn _path -> true end,
        touch_temp: fn _path -> {:error, :eacces} end
      })

    assert {:error, :silent_failure} = Preflight.run([workflow_file], deps)

    fails = collect_puts_err()
    assert Enum.any?(fails, &String.contains?(&1, "Agent availability"))
    assert Enum.any?(fails, &String.contains?(&1, "Workspace root writability"))
    assert Enum.any?(fails, &String.contains?(&1, "Dashboard port"))
  end

  test "legacy workflow without a repo: block warns instead of failing repo clone access" do
    project_slug = "symphony-2e32f5d86d8c"

    # Workflow that mirrors the pre-IDE-61 shape: no top-level `repo:` block,
    # so `settings.repo.url` is nil. Preflight should report that as a [warn]
    # ("legacy workflows hardcode the URL in hooks.after_create") rather than
    # spawning an unauthenticated `git ls-remote` against a missing URL.
    workflow_file =
      tmp_workflow!("legacy-no-repo",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        repo_url: nil,
        repo_path: nil,
        server_port: 0
      )

    deps = build_deps(%{graphql: graphql_responses(project_slug, 0)})

    assert :ok = Preflight.run([workflow_file], deps)

    msgs = collect_puts()
    full = Enum.join(msgs, "\n")

    assert full =~ "[warn] Repo clone access"
    assert full =~ "repo.url not set in WORKFLOW.md"
    refute full =~ "[fail] Repo clone access"

    # The check must not have shelled out to git when the URL is absent.
    refute_received {:system_cmd, "git", _}
  end

  test "fails when gh is the GitHub credential helper but gh is not on PATH" do
    project_slug = "symphony-2e32f5d86d8c"
    repo_url = "git@github.com:org/repo.git"

    workflow_file =
      tmp_workflow!("gh-missing",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        repo_url: repo_url,
        server_port: nil
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        system_cmd: %{
          {"git", ["config", "--get-urlmatch", "credential.helper", "https://github.com"]} => {"!gh auth git-credential\n", 0}
        },
        # gh deliberately absent; git/codex present so other checks pass.
        find_executable: %{"git" => "/usr/bin/git", "codex" => "/usr/bin/codex"}
      })

    assert {:error, :silent_failure} = Preflight.run([workflow_file], deps)

    fails = collect_puts_err()
    assert Enum.any?(fails, &String.contains?(&1, "GitHub credential helper"))
    assert Enum.any?(fails, &String.contains?(&1, "exit 128"))
  end

  test "fails when gh is present but not authenticated" do
    project_slug = "symphony-2e32f5d86d8c"
    repo_url = "git@github.com:org/repo.git"

    workflow_file =
      tmp_workflow!("gh-unauth",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        repo_url: repo_url,
        server_port: nil
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        system_cmd: %{
          {"git", ["config", "--get-urlmatch", "credential.helper", "https://github.com"]} => {"!gh auth git-credential\n", 0},
          {"gh", ["auth", "status"]} => {"You are not logged into any GitHub hosts.", 1}
        }
      })

    assert {:error, :silent_failure} = Preflight.run([workflow_file], deps)

    fails = collect_puts_err()
    assert Enum.any?(fails, &String.contains?(&1, "GitHub credential helper"))
    assert Enum.any?(fails, &String.contains?(&1, "gh auth status exited 1"))
  end

  test "passes when gh is the GitHub credential helper and is authenticated" do
    project_slug = "symphony-2e32f5d86d8c"
    repo_url = "git@github.com:org/repo.git"

    workflow_file =
      tmp_workflow!("gh-ok",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        repo_url: repo_url,
        server_port: 0
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        system_cmd: %{
          {"git", ["config", "--get-urlmatch", "credential.helper", "https://github.com"]} => {"!gh auth git-credential\n", 0},
          {"gh", ["auth", "status"]} => {"Logged in to github.com as tester", 0}
        }
      })

    assert :ok = Preflight.run([workflow_file], deps)

    msgs = collect_puts()
    full = Enum.join(msgs, "\n")
    assert full =~ "[ok]   GitHub credential helper — gh authenticated for GitHub"
  end

  test "skips the gh auth check when a non-gh credential helper is configured" do
    project_slug = "symphony-2e32f5d86d8c"
    repo_url = "git@github.com:org/repo.git"

    workflow_file =
      tmp_workflow!("gh-other-helper",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        repo_url: repo_url,
        server_port: 0
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        system_cmd: %{
          {"git", ["config", "--get-urlmatch", "credential.helper", "https://github.com"]} => {"store\n", 0}
        }
      })

    assert :ok = Preflight.run([workflow_file], deps)

    msgs = collect_puts()
    full = Enum.join(msgs, "\n")
    assert full =~ "[ok]   GitHub credential helper"
    assert full =~ "(not gh); skipping gh auth check"
  end

  test "warns when project resolution fails but missing-state coverage falls back gracefully" do
    project_slug = "symphony-2e32f5d86d8c"

    workflow_file =
      tmp_workflow!("missing-states",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        tracker_active_states: ["Todo", "In Progress"],
        tracker_terminal_states: ["Done", "Closed", "Frobnicate"],
        server_port: nil
      )

    deps =
      build_deps(%{
        graphql:
          graphql_responses(project_slug, 0,
            project:
              {:ok,
               %{
                 "data" => %{
                   "projects" => %{
                     "nodes" => [
                       %{
                         "id" => "p",
                         "name" => "Symphony",
                         "slugId" => project_slug,
                         "teams" => %{
                           "nodes" => [
                             %{
                               "states" => %{
                                 "nodes" => [
                                   %{"name" => "Todo"},
                                   %{"name" => "In Progress"},
                                   %{"name" => "Done"},
                                   %{"name" => "Closed"}
                                 ]
                               }
                             }
                           ]
                         }
                       }
                     ]
                   }
                 }
               }}
          )
      })

    assert {:error, :silent_failure} = Preflight.run([workflow_file], deps)

    fails = collect_puts_err()
    assert Enum.any?(fails, &String.contains?(&1, "Linear state coverage"))
    assert Enum.any?(fails, &String.contains?(&1, "Frobnicate"))
  end

  # --- agent command checking (first-token of agent.<kind>.command) -------

  test "jai-wrapped codex command checks jai on PATH, not codex" do
    project_slug = "symphony-2e32f5d86d8c"

    workflow_file =
      tmp_workflow!("jai-codex",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        codex_command: "jai codex --config sandbox_mode=danger-full-access app-server",
        server_port: nil
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        find_executable: %{"git" => "/usr/bin/git", "jai" => "/usr/local/bin/jai"}
      })

    assert :ok = Preflight.run([workflow_file], deps)

    msgs = collect_puts()
    full = Enum.join(msgs, "\n")

    assert full =~ "Agent availability"
    assert full =~ "codex agent: found jai at /usr/local/bin/jai"
  end

  test "jai-wrapped codex fails when jai is missing even if codex is on PATH" do
    project_slug = "symphony-2e32f5d86d8c"

    workflow_file =
      tmp_workflow!("jai-missing",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        codex_command: "jai codex --config sandbox_mode=danger-full-access app-server",
        server_port: nil
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        # codex present, jai absent — old preflight would have falsely
        # reported the agent as available.
        find_executable: %{"git" => "/usr/bin/git", "codex" => "/usr/bin/codex"}
      })

    assert {:error, :silent_failure} = Preflight.run([workflow_file], deps)

    fails = collect_puts_err()
    assert Enum.any?(fails, &String.contains?(&1, "Agent availability"))
    assert Enum.any?(fails, &String.contains?(&1, "jai not found on PATH"))
  end

  test "claude agent.kind reads command from agent.claude.command (regression)" do
    # Regression: preflight previously looked up `settings.claude.command`,
    # which the schema never populates — only `settings.agent.claude` exists
    # (the `codex` mirror at top-level is a legacy alias that has no claude
    # counterpart). Result: every `agent.kind: claude` workflow crashed
    # preflight with a `KeyError key :claude not found` from check_agent/2.
    project_slug = "symphony-claude-2e32f5d86d8c"

    workflow_root = Path.join(System.tmp_dir!(), "preflight-claude-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workflow_root)
    workflow_file = Path.join(workflow_root, "WORKFLOW.md")
    on_exit(fn -> File.rm_rf(workflow_root) end)

    File.write!(workflow_file, """
    ---
    tracker:
      kind: linear
      api_key: secret
      project_slug: #{project_slug}
      active_states:
        - Todo
        - In Progress
      terminal_states:
        - Done
        - Canceled
        - Duplicate
    workspace:
      root: #{Path.join(System.tmp_dir!(), "ws-claude-#{System.unique_integer([:positive])}")}
    agent:
      kind: claude
      claude:
        command: uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent
        permission_mode: dontAsk
        allowed_tools:
          - Read
          - Bash
    hooks:
      timeout_ms: 60000
    ---

    prompt
    """)

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        find_executable: %{"git" => "/usr/bin/git", "uv" => "/usr/local/bin/uv"}
      })

    assert :ok = Preflight.run([workflow_file], deps)

    msgs = collect_puts()
    full = Enum.join(msgs, "\n")

    assert full =~ "Agent availability"
    assert full =~ "claude sidecar: found uv at /usr/local/bin/uv"
  end

  test "env-backed agent command warns instead of failing the check" do
    project_slug = "symphony-2e32f5d86d8c"

    workflow_file =
      tmp_workflow!("env-backed",
        tracker_api_token: "secret",
        tracker_project_slug: project_slug,
        codex_command: "$CODEX_BIN --config 'model=\"gpt-5.5\"' app-server",
        server_port: nil
      )

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        find_executable: %{"git" => "/usr/bin/git"}
      })

    assert :ok = Preflight.run([workflow_file], deps)

    msgs = collect_puts()
    full = Enum.join(msgs, "\n")

    assert full =~ "[warn] Agent availability"
    assert full =~ "env-backed value"
    assert full =~ "$CODEX_BIN"
  end

  defp collect_graphql_queries do
    receive do
      {:graphql, query, _vars} -> [query | collect_graphql_queries()]
    after
      0 -> []
    end
  end

  defp collect_graphql_pairs do
    receive do
      {:graphql, query, vars} -> [{query, vars} | collect_graphql_pairs()]
    after
      0 -> []
    end
  end

  defp collect_puts do
    receive do
      {:puts, msg} -> [msg | collect_puts()]
    after
      0 -> []
    end
  end

  defp collect_puts_err do
    receive do
      {:puts_err, msg} -> [msg | collect_puts_err()]
    after
      0 -> []
    end
  end
end
