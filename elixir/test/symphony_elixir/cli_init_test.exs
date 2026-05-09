defmodule SymphonyElixir.CLI.InitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI.Init
  alias SymphonyElixir.Config.Schema

  defp capture_deps do
    parent = self()

    %{
      file_exists?: fn _path -> false end,
      write: fn path, contents ->
        send(parent, {:write, path, IO.iodata_to_binary(contents)})
        :ok
      end,
      mkdir_p: fn path ->
        send(parent, {:mkdir, path})
        :ok
      end,
      puts: fn output ->
        send(parent, {:puts, IO.iodata_to_binary(output)})
        :ok
      end
    }
  end

  test "rejects a missing --linear-project flag" do
    assert {:error, message} =
             Init.run(["--repo-url", "git@github.com:org/repo.git"], capture_deps())

    assert message =~ "--linear-project is required"
  end

  test "rejects a missing --repo-url flag" do
    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "https://linear.app/identione/project/symphony-2e32f5d86d8c"
               ],
               capture_deps()
             )

    assert message =~ "--repo-url is required"
  end

  test "rejects an invalid --agent value" do
    deps = capture_deps()

    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "https://linear.app/identione/project/symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--agent",
                 "gemini"
               ],
               deps
             )

    assert message =~ "invalid --agent"
    refute_received {:write, _path, _contents}
  end

  test "rejects unknown switches" do
    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--bogus",
                 "yes"
               ],
               capture_deps()
             )

    assert message =~ "invalid flags"
  end

  test "writes a Codex workflow with env-backed Linear API key and default states" do
    deps = capture_deps()
    output = Path.join(System.tmp_dir!(), "WORKFLOW-init-#{System.unique_integer([:positive])}.md")

    on_exit(fn -> File.rm(output) end)

    assert :ok =
             Init.run(
               [
                 "--linear-project",
                 "https://linear.app/identione/project/symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--agent",
                 "codex",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:mkdir, mkdir_path}
    assert mkdir_path == Path.dirname(output)
    assert_received {:write, ^output, contents}

    assert contents =~ "kind: linear"
    assert contents =~ "api_key: $LINEAR_API_KEY"
    assert contents =~ "project_slug: \"symphony-2e32f5d86d8c\""
    assert contents =~ "Todo"
    assert contents =~ "In Progress"
    assert contents =~ "Done"
    assert contents =~ "Cancelled"
    assert contents =~ "Canceled"
    assert contents =~ "Duplicate"
    refute contents =~ "Human Review"
    refute contents =~ "Rework"
    refute contents =~ "Merging"
    assert contents =~ "kind: codex"
    assert contents =~ "command: codex app-server"
    assert contents =~ "git clone --depth 1"
    assert contents =~ "git@github.com:org/repo.git"
    assert contents =~ "repo:"
    assert contents =~ "url: \"git@github.com:org/repo.git\""

    assert_received {:puts, output_message}
    assert output_message =~ "Wrote #{output}"
    assert output_message =~ "symphony preflight #{output}"

    assert output_message =~
             "symphony start --i-understand-that-this-will-be-running-without-the-usual-guardrails #{output}"
  end

  test "writes a Claude workflow that drops jai (portable default)" do
    deps = capture_deps()
    output = Path.join(System.tmp_dir!(), "WORKFLOW-init-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(output) end)

    assert :ok =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--agent",
                 "claude",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, _path, contents}

    assert contents =~ "kind: claude"
    assert contents =~ "uv run --project $SYMPHONY_CLAUDE_PRIV_DIR python -m symphony_claude_agent"
    refute contents =~ "jai uv run"
    assert contents =~ "permission_mode: dontAsk"
    assert contents =~ "mcp__symphony__linear_graphql"
    assert contents =~ "setting_sources: []"
  end

  test "default workspace root derives from repo URL" do
    deps = capture_deps()
    output = Path.join(System.tmp_dir!(), "WORKFLOW-init-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(output) end)

    assert :ok =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:Identione/symphony.git",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, _path, contents}

    assert contents =~ "root: \"~/code/symphony-workspaces/symphony\""
  end

  test "honours --workspace-root and optional --repo-path" do
    deps = capture_deps()
    output = Path.join(System.tmp_dir!(), "WORKFLOW-init-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(output) end)

    assert :ok =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--workspace-root",
                 "/srv/work/repo",
                 "--repo-path",
                 "/home/dev/code/repo",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, _path, contents}

    assert contents =~ "root: \"/srv/work/repo\""
    assert contents =~ "path: \"/home/dev/code/repo\""
  end

  test "refuses to overwrite an existing file unless --force" do
    parent = self()

    deps = %{
      capture_deps()
      | file_exists?: fn _path -> true end
    }

    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--output",
                 "/tmp/existing.md"
               ],
               deps
             )

    assert message =~ "refusing to overwrite"
    refute_received {:write, _path, _contents}

    forced_deps = %{
      capture_deps()
      | file_exists?: fn _path -> true end,
        write: fn path, contents ->
          send(parent, {:write_forced, path, IO.iodata_to_binary(contents)})
          :ok
        end
    }

    assert :ok =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--output",
                 "/tmp/existing.md",
                 "--force"
               ],
               forced_deps
             )

    assert_received {:write_forced, "/tmp/existing.md", _}
  end

  test "wraps repo URLs containing shell metacharacters in single quotes" do
    # Operator-supplied repo URL with shell-active characters: dollar sign,
    # backtick, backslash, double quote, apostrophe. The generated hook line
    # must single-quote the URL so that none of these expand when an unattended
    # `hooks.after_create` shell later runs the workflow.
    repo_url = ~S{git@example.com:o`r$g/repo\name'with".git}

    rendered =
      Init.render_workflow(%{
        project_slug: "symphony-2e32f5d86d8c",
        repo_url: repo_url,
        repo_path: nil,
        agent: "codex",
        workspace_root: "~/code/symphony-workspaces/repo"
      })

    [hook_line] =
      rendered
      |> String.split(~r/\R/)
      |> Enum.filter(&String.contains?(&1, "git clone --depth 1"))

    # POSIX-safe: a single outer quote pair, with every embedded `'` rewritten
    # as `'\''` (close, escaped quote, reopen). No backslash, dollar sign, or
    # backtick escapes the quoted region.
    expected_hook =
      ~S{    git clone --depth 1 'git@example.com:o`r$g/repo\name} <>
        ~S{'\''} <> ~S{with".git' .}

    assert hook_line == expected_hook

    # YAML scalar: backslashes doubled, double quotes escaped — a round-trip
    # through YamlElixir must recover the exact input.
    {:ok, decoded} =
      rendered
      |> String.split(~r/\R/, trim: false)
      |> Enum.drop(1)
      |> Enum.take_while(&(&1 != "---"))
      |> Enum.join("\n")
      |> YamlElixir.read_from_string()

    assert get_in(decoded, ["repo", "url"]) == repo_url
  end

  test "generated workflow parses against the Symphony schema" do
    rendered =
      Init.render_workflow(%{
        project_slug: "symphony-2e32f5d86d8c",
        repo_url: "git@github.com:org/repo.git",
        repo_path: nil,
        agent: "codex",
        workspace_root: "~/code/symphony-workspaces/repo"
      })

    {:ok, ["---" | rest]} = {:ok, String.split(rendered, ~r/\R/, trim: false)}
    assert "---" in rest
    {front, _} = Enum.split_while(rest, &(&1 != "---"))
    yaml = Enum.join(front, "\n")
    {:ok, decoded} = YamlElixir.read_from_string(yaml)

    assert {:ok, %Schema{} = settings} = Schema.parse(decoded)
    assert settings.tracker.kind == "linear"
    assert "Todo" in settings.tracker.active_states
    assert "Done" in settings.tracker.terminal_states
    assert settings.agent.kind == "codex"
    assert settings.repo.url == "git@github.com:org/repo.git"
  end
end
