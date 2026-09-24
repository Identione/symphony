defmodule SymphonyElixir.Scripts.ResyncInstanceBodiesTest do
  # Drives scripts/resync_instance_bodies.exs (the `make resync-bodies` /
  # `check-bodies` backend and each instance's preflight body check) against a
  # temp instance file: the body must be re-derived from the instance's OWN
  # `repo.base_branch` / `repo.gate_command` / `repo.worker_notes`, with the
  # front matter preserved byte-for-byte.
  use ExUnit.Case, async: true

  @script Path.expand("../../../scripts/resync_instance_bodies.exs", __DIR__)
  @template Path.expand("../../../priv/templates/workflow.md.eex", __DIR__)
  @marker "You are working on a Linear ticket"

  @front_matter """
  ---
  tracker:
    kind: linear
    project_slug: "x"
  repo:
    url: "git@github.com:org/repo.git"
    base_branch: "develop"
    # comment lines between keys are fine
    gate_command: "./scripts/gate.sh --fast"
    worker_notes: |
      First rule ({{ issue.identifier }}).

      Second rule.
  hooks:
    after_create: |
      git clone --filter=blob:none --branch 'develop' 'git@github.com:org/repo.git' .
  agent:
    kind: claude
  ---
  """

  defp run(args) do
    {out, status} = System.cmd("elixir", [@script | args], stderr_to_stdout: true)
    {out, status}
  end

  defp expected_body do
    [_, rest] = String.split(File.read!(@template), @marker, parts: 2)

    EEx.eval_string(@marker <> rest,
      assigns: [
        base_branch: "develop",
        gate_command: "./scripts/gate.sh --fast",
        worker_notes: "First rule ({{ issue.identifier }}).\n\nSecond rule.",
        delegation_mode: nil
      ]
    )
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "resync-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, path: Path.join(dir, "WORKFLOW.md")}
  end

  test "--check reports drift, a plain run re-bakes the body from the front matter knobs", %{
    path: path
  } do
    File.write!(path, @front_matter <> @marker <> " `{{ issue.identifier }}` STALE BODY\n")

    assert {out, 1} = run(["--check", path])
    assert out =~ "DRIFT"
    assert out =~ ~s(base="develop" gate="./scripts/gate.sh --fast" notes=yes)
    # --check never writes.
    assert File.read!(path) =~ "STALE BODY"

    assert {out, 0} = run([path])
    assert out =~ "RESYNCED"

    resynced = File.read!(path)
    assert String.starts_with?(resynced, @front_matter)
    [_, body] = String.split(resynced, @marker, parts: 2)
    assert @marker <> body == expected_body()
    # The knobs reached the body: gate sentence, joined notes, base refs.
    assert resynced =~ "Run the gate as `./scripts/gate.sh --fast` from the repo root."
    assert resynced =~ "First rule ({{ issue.identifier }}). Second rule.\" Prefer"
    assert resynced =~ "origin/develop"

    assert {out, 0} = run(["--check", path])
    assert out =~ "in sync"
  end

  test "an instance without the knobs renders the generic body", %{path: path} do
    header = """
    ---
    repo:
      url: "git@github.com:org/repo.git"
    ---
    """

    File.write!(path, header <> @marker <> " stale\n")
    assert {out, 0} = run([path])
    assert out =~ ~s(base=nil gate=nil notes=no mode=nil)
    resynced = File.read!(path)
    assert resynced =~ "repository's documented full local quality gate command"
    assert resynced =~ "origin/main"
    refute resynced =~ "symphony/{{ issue.identifier }}"
  end

  test "repo.delegation_mode: workflow bakes the Workflow mode rule into the body", %{path: path} do
    header = """
    ---
    repo:
      url: "git@github.com:org/repo.git"
      delegation_mode: "workflow"
    ---
    """

    File.write!(path, header <> @marker <> " stale\n")
    assert {out, 0} = run([path])
    assert out =~ ~s(mode="workflow")
    assert File.read!(path) =~ "Workflow mode"
    assert {_, 0} = run(["--check", path])
  end
end
