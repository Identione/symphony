defmodule SymphonyElixir.CLI.InitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI.Init
  alias SymphonyElixir.Config.Schema

  defp capture_deps(overrides \\ %{}) do
    parent = self()

    base = %{
      file_exists?: fn _path -> false end,
      write: fn path, contents ->
        send(parent, {:write, path, IO.iodata_to_binary(contents)})
        :ok
      end,
      mkdir_p: fn path ->
        send(parent, {:mkdir, path})
        :ok
      end,
      program_name: Map.get(overrides, :program_name, fn -> "symphony" end),
      puts: fn output ->
        send(parent, {:puts, IO.iodata_to_binary(output)})
        :ok
      end,
      read_template: &read_template_from_disk/1
    }

    Map.merge(base, Map.drop(overrides, [:program_name]))
  end

  defp read_template_from_disk(name) do
    relative =
      case name do
        :workflow -> "priv/templates/workflow.md.eex"
        :instance_makefile -> "priv/templates/instance.Makefile.eex"
      end

    File.read(Application.app_dir(:symphony_elixir, relative))
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
    assert contents =~ "Canceled"
    assert contents =~ "Duplicate"
    refute contents =~ "Cancelled"
    refute contents =~ "Closed"
    # The generated workflow now embeds the full canonical state machine and
    # prompt body, so instances drive Human Review / Merging / Rework exactly
    # like the maintainer's elixir/WORKFLOW.md.
    assert contents =~ "Human Review"
    assert contents =~ "Rework"
    assert contents =~ "Merging"
    assert contents =~ "## Symphony Workpad"
    assert contents =~ "PR feedback sweep protocol"
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

  test "--base-branch bakes the base into front matter, clone hook, and prompt body" do
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
                 "--base-branch",
                 "develop",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, ^output, contents}

    # Front matter: a `base_branch:` line nested under `repo:`.
    assert contents =~ "base_branch: \"develop\""
    # Clone hook fetches the base and records it for the base-aware skills.
    assert contents =~ "git fetch --depth 1 origin 'develop:refs/remotes/origin/develop'"
    assert contents =~ "git config symphony.baseBranch 'develop'"
    # Body references the configured base, never origin/main.
    assert contents =~ "origin/develop"
    refute contents =~ "origin/main"
    # The issue-branch isolation section is present.
    assert contents =~ "symphony/{{ issue.identifier }}"

    assert_received {:puts, output_message}
    assert output_message =~ "Base branch 'develop'"
  end

  test "without --base-branch the clone hook is a bare clone and the body keeps origin/main" do
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
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, ^output, contents}

    # No base_branch front-matter line, no base-aware clone-hook lines.
    refute contents =~ "base_branch:"
    refute contents =~ "git fetch --depth 1 origin"
    refute contents =~ "git config symphony.baseBranch"
    # Body keeps today's origin/main and emits no issue-branch isolation section.
    assert contents =~ "origin/main"
    refute contents =~ "symphony/{{ issue.identifier }}"

    # after_create stays exactly the single clone line, with `agent:` on the very
    # next line (no stray blank line from the nil-case EEx conditional). The
    # clone hook lives in the front matter, which the byte-identity body test
    # does not cover — this guards the nil render directly.
    lines = String.split(contents, "\n")
    clone_idx = Enum.find_index(lines, &String.contains?(&1, "git clone --depth 1"))
    assert clone_idx
    assert Enum.at(lines, clone_idx) == "    git clone --depth 1 'git@github.com:org/repo.git' ."
    assert Enum.at(lines, clone_idx + 1) == "agent:"
  end

  test "rejects --base-branch values that are not safe git branch names" do
    # Note: a leading-`-` value (e.g. "-x") is also rejected, but OptionParser
    # intercepts it before validate_base_branch runs (a token starting with `-`
    # is not consumed as the flag's argument), so it surfaces as "invalid flags"
    # rather than this message — excluded here; the leading-`-` guard in
    # validate_base_branch still defends non-CLI callers.
    for bad <- ["bad branch", "has..dots", "ref@{0}", "trailing/", "x.lock", "a;b", "$(x)"] do
      deps = capture_deps()

      assert {:error, message} =
               Init.run(
                 [
                   "--linear-project",
                   "symphony-2e32f5d86d8c",
                   "--repo-url",
                   "git@github.com:org/repo.git",
                   "--base-branch",
                   bad
                 ],
                 deps
               ),
             "expected #{inspect(bad)} to be rejected"

      assert message =~ "--base-branch must be a valid git branch name"
      refute_received {:write, _path, _contents}
    end
  end

  test "template prompt body stays byte-identical to the canonical elixir/WORKFLOW.md body" do
    # Single-source guard: the init template inlines the canonical prompt body so
    # generated instances behave exactly like elixir/WORKFLOW.md. If either file's
    # body drifts from the other, this fails loudly and both must be updated together.
    #
    # The template body now carries optional base-branch EEx (`@base_branch` — the
    # only assign the body references). We render it with `base_branch: nil` (the
    # default-instance case), which reproduces the canonical hardcoded
    # `origin/main` body and omits the issue-branch section. The base-branch
    # render is exercised separately by the `--base-branch` init test.
    {:ok, template} =
      File.read(Application.app_dir(:symphony_elixir, "priv/templates/workflow.md.eex"))

    {:ok, canonical} = File.read(Path.join(File.cwd!(), "WORKFLOW.md"))

    marker = "You are working on a Linear ticket"

    body_of = fn contents ->
      [_front, body] = String.split(contents, marker, parts: 2)
      String.trim(marker <> body)
    end

    rendered_template_body =
      EEx.eval_string(body_of.(template), assigns: [base_branch: nil])

    assert rendered_template_body == body_of.(canonical)
  end

  test "prints next-step commands using whichever invocation form the operator used" do
    # Regression: previously the printed lines always read `symphony preflight …`
    # and `symphony start …` regardless of how the binary was invoked. A user
    # who just ran `./bin/symphony init …` would copy-paste a command that does
    # not work in their shell because `symphony` is not on PATH yet. Inject a
    # program_name and assert the printed commands mirror it verbatim.
    deps = capture_deps(%{program_name: fn -> "./bin/symphony" end})
    output = Path.join(System.tmp_dir!(), "WORKFLOW-init-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(output) end)

    assert :ok =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:puts, output_message}
    assert output_message =~ "./bin/symphony preflight #{output}"

    assert output_message =~
             "./bin/symphony start --i-understand-that-this-will-be-running-without-the-usual-guardrails #{output}"
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
    # Default ships allow-all: bypassPermissions active, the dontAsk whitelist
    # (incl. the linear_graphql MCP tool) commented out as a swap-ready opt-in.
    assert contents =~ "permission_mode: bypassPermissions"
    refute contents =~ ~r/^\s*permission_mode: dontAsk/m
    assert contents =~ "#  - mcp__symphony__linear_graphql"
    assert contents =~ "#  - mcp__symphony__sync_workpad"
    # `setting_sources` ships commented-out: the default (unset) loads the
    # repo's Claude settings/.mcp.json/CLAUDE.md like an interactive run, and
    # the line is offered as a swap-ready isolation opt-out.
    assert contents =~ "#setting_sources: []"

    # The jai-wrapped form is shipped as a commented swap-ready alternative
    # (`#command: jai uv run …`), so the bare substring "jai uv run" appears
    # in the rendered file. The generator also renders BOTH agent.claude and
    # agent.codex blocks now, so there are multiple active `command:` lines
    # in the file. What we actually care about: the claude-specific active
    # command line (the one containing `uv run --project`) is the non-jai
    # variant. Catch both regressions: claude active line accidentally
    # jai-wrapped, and no claude active line at all.
    active_claude_command =
      contents
      |> String.split(~r/\R/)
      |> Enum.find(&Regex.match?(~r/^\s*command:.*uv run/, &1))

    assert active_claude_command
    refute active_claude_command =~ "jai"
    assert active_claude_command =~ "uv run --project $SYMPHONY_CLAUDE_PRIV_DIR"
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

  test "default workspace root handles SCP-style URLs without a slash separator" do
    # Regression: repo_basename used Path.basename, which only splits on `/`.
    # For an SCP-form URL like `git@example.com:repo.git` (no `/`) the basename
    # was the full string and the rendered workspace path leaked the host —
    # `~/code/symphony-workspaces/git@example.com:repo`. The generator must
    # also split on `:` so SCP-form URLs reduce to the bare repo name.
    deps = capture_deps()
    output = Path.join(System.tmp_dir!(), "WORKFLOW-init-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(output) end)

    assert :ok =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@example.com:repo.git",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, _path, contents}

    assert contents =~ "root: \"~/code/symphony-workspaces/repo\""
    refute contents =~ "symphony-workspaces/git@"
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
    # Schema default for agent.max_concurrent_agents is 10; the generator must
    # not paper over it with a lower hard-coded number. Operators can override
    # via the YAML; the generator's job is to surface the same default as
    # everything else.
    assert settings.agent.max_concurrent_agents == 10
  end

  # --- template loaded from disk -------------------------------------------

  test "renders the workflow from the read_template dep (not a baked-in iolist)" do
    sentinel = "SENTINEL_TEMPLATE_BODY_<%= @project_slug %>\n"

    deps =
      capture_deps(%{
        read_template: fn
          :workflow -> {:ok, sentinel}
          :instance_makefile -> {:error, :should_not_be_called}
        end
      })

    output = Path.join(System.tmp_dir!(), "WORKFLOW-init-#{System.unique_integer([:positive])}.md")
    on_exit(fn -> File.rm(output) end)

    assert :ok =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, ^output, contents}
    assert contents =~ "SENTINEL_TEMPLATE_BODY_\"symphony-2e32f5d86d8c\""
  end

  # --- --port flag ---------------------------------------------------------

  test "--port N renders an active server block and drops the commented hint" do
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
                 "--port",
                 "4000",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, ^output, contents}
    assert contents =~ ~r/^server:\n  port: 4000$/m
    refute contents =~ "# server:"
    refute contents =~ "port: 3453"
  end

  test "no --port produces no server block at all" do
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
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, ^output, contents}
    refute contents =~ "server:"
    refute contents =~ "port:"
    refute contents =~ "3453"
  end

  test "--port 0 is accepted and produces server.port: 0" do
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
                 "--port",
                 "0",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, ^output, contents}
    assert contents =~ ~r/^server:\n  port: 0$/m
  end

  test "--port -1 is rejected" do
    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--port",
                 "-1"
               ],
               capture_deps()
             )

    assert message =~ ~r/--port/
    refute_received {:write, _path, _contents}
  end

  test "--port abc is rejected by OptionParser type coercion" do
    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--port",
                 "abc"
               ],
               capture_deps()
             )

    assert message =~ "invalid flags"
    refute_received {:write, _path, _contents}
  end

  # --- --host flag ---------------------------------------------------------

  test "--port N --host 0.0.0.0 renders host line in the server block" do
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
                 "--port",
                 "3454",
                 "--host",
                 "0.0.0.0",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, ^output, contents}
    assert contents =~ ~r/^server:\n  port: 3454\n  host: "0\.0\.0\.0"$/m
  end

  test "--host accepts IPv6 literals" do
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
                 "--port",
                 "3454",
                 "--host",
                 "::1",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, ^output, contents}
    assert contents =~ ~s|host: "::1"|
  end

  test "--host rejects DNS hostnames (strict IP-literal validation)" do
    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--port",
                 "3454",
                 "--host",
                 "dashboard.local"
               ],
               capture_deps()
             )

    assert message =~ ~r/--host must be a literal IPv4 or IPv6 address/
    refute_received {:write, _path, _contents}
  end

  test "--host rejects partial IPv4 typos like 0.0.0" do
    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--port",
                 "3454",
                 "--host",
                 "0.0.0"
               ],
               capture_deps()
             )

    assert message =~ ~r/--host must be a literal IPv4 or IPv6 address/
    refute_received {:write, _path, _contents}
  end

  test "--host rejects empty string" do
    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--port",
                 "3454",
                 "--host",
                 ""
               ],
               capture_deps()
             )

    assert message =~ ~r/--host/
    refute_received {:write, _path, _contents}
  end

  test "--host without --port is rejected" do
    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--host",
                 "0.0.0.0"
               ],
               capture_deps()
             )

    assert message =~ ~r/--host requires --port/
    refute_received {:write, _path, _contents}
  end

  test "generated workflow with --port and --host still parses against the schema" do
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
                 "--port",
                 "4000",
                 "--host",
                 "0.0.0.0",
                 "--output",
                 output
               ],
               deps
             )

    assert_received {:write, ^output, contents}

    [_first | rest] = String.split(contents, ~r/\R/, trim: false)
    {front, _} = Enum.split_while(rest, &(&1 != "---"))
    yaml = Enum.join(front, "\n")
    {:ok, decoded} = YamlElixir.read_from_string(yaml)

    assert {:ok, %Schema{} = settings} = Schema.parse(decoded)
    assert settings.server.port == 4000
    assert settings.server.host == "0.0.0.0"
  end

  # --- --instance-makefile / --instance-name -------------------------------

  test "--instance-makefile renders a second template through the same EEx pipeline" do
    deps = capture_deps()
    workflow_out = Path.join(System.tmp_dir!(), "WORKFLOW-init-#{System.unique_integer([:positive])}.md")

    makefile_out =
      Path.join(System.tmp_dir!(), "Makefile-init-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm(workflow_out)
      File.rm(makefile_out)
    end)

    assert :ok =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--output",
                 workflow_out,
                 "--instance-makefile",
                 makefile_out,
                 "--instance-name",
                 "repo-a"
               ],
               deps
             )

    assert_received {:write, ^workflow_out, _workflow_contents}
    assert_received {:write, ^makefile_out, makefile_contents}

    expected_instance_dir = Path.dirname(makefile_out)

    assert makefile_contents =~ "INSTANCE_DIR  := #{expected_instance_dir}"
    assert makefile_contents =~ "ROOT          := "
    assert makefile_contents =~ "INSTANCE=repo-a"
    refute makefile_contents =~ "3453"
    refute makefile_contents =~ "DASHBOARD_URL"

    # The instance Makefile must expose `make upgrade` (with a help-line `## `
    # description) plus the private `_upgrade-restart-if-running` helper that
    # the root Makefile's `upgrade-all` invokes per-instance via
    # `$(MAKE) -C <instance> …` so the build happens once, not once per instance.
    assert makefile_contents =~ ~r/^upgrade:.*## /m

    # Collapse `\\\n` line-continuations so the .PHONY declaration lands on
    # a single logical line regardless of how it's wrapped in the template.
    flattened = String.replace(makefile_contents, ~r/\\\n\s*/, " ")
    assert flattened =~ ~r/^\.PHONY:.*\bupgrade\b/m
    assert flattened =~ ~r/^\.PHONY:.*\b_upgrade-restart-if-running\b/m
  end

  test "--instance-makefile without --instance-name is rejected" do
    workflow_out = Path.join(System.tmp_dir!(), "WORKFLOW-init-#{System.unique_integer([:positive])}.md")

    makefile_out =
      Path.join(System.tmp_dir!(), "Makefile-init-#{System.unique_integer([:positive])}")

    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--output",
                 workflow_out,
                 "--instance-makefile",
                 makefile_out
               ],
               capture_deps()
             )

    assert message =~ ~r/--instance-makefile requires --instance-name/
    refute_received {:write, _path, _contents}
  end

  test "--instance-name with path-unsafe characters is rejected" do
    for bad <- ["foo/bar", "foo bar", ".hidden", "..", "../escape", "name;with;semi"] do
      assert {:error, message} =
               Init.run(
                 [
                   "--linear-project",
                   "symphony-2e32f5d86d8c",
                   "--repo-url",
                   "git@github.com:org/repo.git",
                   "--instance-makefile",
                   "/tmp/dummy",
                   "--instance-name",
                   bad
                 ],
                 capture_deps()
               ),
             "expected #{inspect(bad)} to be rejected"

      assert message =~ ~r/--instance-name/, "for input #{inspect(bad)}"
    end

    refute_received {:write, _path, _contents}
  end

  test "force gate refuses both files when either output exists, without --force" do
    parent = self()
    workflow_out = "/tmp/init-force-test-WORKFLOW.md"
    makefile_out = "/tmp/init-force-test-Makefile"

    deps = %{
      capture_deps()
      | file_exists?: fn
          ^workflow_out -> true
          _other -> false
        end
    }

    assert {:error, message} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--output",
                 workflow_out,
                 "--instance-makefile",
                 makefile_out,
                 "--instance-name",
                 "repo-a"
               ],
               deps
             )

    assert message =~ "refusing to overwrite"
    refute_received {:write, _path, _contents}

    deps_makefile_exists = %{
      capture_deps()
      | file_exists?: fn
          ^makefile_out -> true
          _other -> false
        end
    }

    assert {:error, message_makefile} =
             Init.run(
               [
                 "--linear-project",
                 "symphony-2e32f5d86d8c",
                 "--repo-url",
                 "git@github.com:org/repo.git",
                 "--output",
                 workflow_out,
                 "--instance-makefile",
                 makefile_out,
                 "--instance-name",
                 "repo-a"
               ],
               deps_makefile_exists
             )

    assert message_makefile =~ "refusing to overwrite"
    refute_received {:write, _path, _contents}

    forced_deps = %{
      capture_deps()
      | file_exists?: fn _ -> true end,
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
                 workflow_out,
                 "--instance-makefile",
                 makefile_out,
                 "--instance-name",
                 "repo-a",
                 "--force"
               ],
               forced_deps
             )

    assert_received {:write_forced, ^workflow_out, _}
    assert_received {:write_forced, ^makefile_out, _}
  end
end
