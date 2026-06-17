defmodule SymphonyElixir.OrchestratorProgressSignalTest do
  @moduledoc """
  Drives synthetic per-turn worker updates through the orchestrator's
  turn-boundary hook against a real throwaway git workspace, asserting the
  Layer-1 progress signals (IDE-189) advance and surface via `snapshot/0` for
  both adapters. Layer 1 only reports — these tests assert no enforcement.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-progress-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    File.write!(Path.join(dir, "seed.txt"), "v0\n")
    git!(dir, ["add", "seed.txt"])
    git!(dir, ["commit", "-qm", "initial"])
    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  defp git!(dir, args) do
    {out, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    String.trim(out)
  end

  defp start_orchestrator(label) do
    name = Module.concat(__MODULE__, label)
    {:ok, pid} = Orchestrator.start_link(name: name, poll_on_start: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  defp seed_running(pid, issue, workspace) do
    entry = %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      session_id: "sess-#{issue.identifier}",
      workspace_path: workspace,
      turn_count: 0,
      dispatch_head: nil,
      progress: SymphonyElixir.ProgressSignal.new(),
      progress_assessment: SymphonyElixir.ProgressSignal.default_assessment(),
      retry_attempt: 0,
      started_at: DateTime.utc_now()
    }

    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue.id => entry})
      |> Map.put(:claimed, MapSet.new([issue.id]))
    end)
  end

  defp progress_for(pid, issue_id) do
    :sys.get_state(pid).running[issue_id].progress_assessment
  end

  test "claude: a distinct dirty edit each turn => progressing + at_risk from turn 4", %{dir: dir} do
    pid = start_orchestrator(:Claude)
    issue = %Issue{id: "issue-claude", identifier: "PRG-1", title: "t", state: "In Progress", url: "u"}
    # A tracked file so each turn's distinct content changes the porcelain+diff
    # hash (mirrors IDE-189's modified `Containerfile`). The commit predates the
    # first probe, so dispatch_head is captured after it and commits_since stays 0.
    File.write!(Path.join(dir, "work.txt"), "v0\n")
    git!(dir, ["add", "work.txt"])
    git!(dir, ["commit", "-qm", "add work"])
    seed_running(pid, issue, dir)

    for turn <- 1..5 do
      File.write!(Path.join(dir, "work.txt"), "edit-#{turn}\n")
      send(pid, {:codex_worker_update, issue.id, %{agent_kind: :claude, event: :turn_completed, timestamp: DateTime.utc_now()}})
      # serialize: a sync call flushes the async cast/info ahead of it
      _ = :sys.get_state(pid)

      assessment = progress_for(pid, issue.id)
      assert assessment.status == :progressing

      if turn >= 4 do
        assert assessment.at_risk_no_commits
      end
    end

    assert progress_for(pid, issue.id).evidence.tree_hash_streak == 1
  end

  test "codex: an empty tree for K turns => stuck_state, surfaced via snapshot/0", %{dir: dir} do
    pid = start_orchestrator(:Codex)
    issue = %Issue{id: "issue-codex", identifier: "PRG-2", title: "t", state: "In Progress", url: "u"}
    seed_running(pid, issue, dir)

    for turn <- 1..4 do
      # New session_id each turn so the codex turn_count ticks; tree stays clean.
      send(pid, {:codex_worker_update, issue.id, %{event: :session_started, session_id: "s-#{turn}", timestamp: DateTime.utc_now()}})
      _ = :sys.get_state(pid)
    end

    assessment = progress_for(pid, issue.id)
    assert assessment.status == :stuck_state
    assert assessment.evidence.wt_empty

    snap = Orchestrator.snapshot(Module.concat(__MODULE__, :Codex), 2_000)
    running = Enum.find(snap.running, &(&1.issue_id == issue.id))
    assert running.progress_assessment.status == :stuck_state
  end
end
