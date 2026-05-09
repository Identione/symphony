defmodule SymphonyElixir.CLI.PreflightTest do
  use SymphonyElixir.TestSupport

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
      mkdir_p: Map.get(overrides, :mkdir_p, fn _path -> :ok end),
      touch_temp: Map.get(overrides, :touch_temp, fn _path -> :ok end),
      tcp_listen: fn _port -> Map.get(overrides, :tcp_listen, :ok) end,
      graphql: fn query, vars ->
        send(parent, {:graphql, query, vars})
        responses = Map.get(overrides, :graphql, %{})
        find_response(responses, query)
      end,
      # No-ops in tests: graphql is mocked, so we don't need the Req app, and
      # mutating the global Logger level here would leak into other suites.
      ensure_http_app: fn -> :ok end,
      silence_logger: fn -> :ok end,
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

    deps = build_deps(%{graphql: graphql_responses(project_slug, 2)})

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

    assert full =~
             "symphony start --i-understand-that-this-will-be-running-without-the-usual-guardrails"
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

    parent = self()

    deps =
      build_deps(%{
        graphql: graphql_responses(project_slug, 0),
        find_executable: %{"git" => "/usr/bin/git"},
        tcp_listen: {:error, :eaddrinuse},
        mkdir_p: fn path ->
          send(parent, {:mkdir_attempt, path})
          {:error, :eacces}
        end
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
