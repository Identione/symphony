defmodule SymphonyElixir.OrchestratorProgressSignalTest do
  @moduledoc """
  Integration coverage for IDE-211 Layer 1: drives synthetic turn-boundary
  worker updates through the orchestrator against a real throwaway git
  workspace and asserts the rolling progress signals advance and surface via
  `snapshot/0`. Covers both adapters (claude `:turn_completed` and codex
  `:session_started` ticks).
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.ProgressSignal

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-progress-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    File.write!(Path.join(dir, "tracked.txt"), "v1\n")
    git!(dir, ["add", "tracked.txt"])
    git!(dir, ["commit", "-q", "-m", "initial"])
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
    {:ok, pid} = SymphonyElixir.Orchestrator.start_link(name: name, poll_on_start: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)
    pid
  end

  defp issue(id) do
    %Issue{
      id: id,
      identifier: "PRG-1",
      title: "Progress",
      state: "In Progress",
      url: "https://example.org/issues/PRG-1"
    }
  end

  defp running_entry(issue, dir, agent_kind) do
    %{
      pid: self(),
      ref: make_ref(),
      identifier: issue.identifier,
      issue: issue,
      worker_host: nil,
      workspace_path: dir,
      session_id: "sess-PRG-1",
      agent_kind: agent_kind,
      last_codex_message: nil,
      last_codex_timestamp: nil,
      last_codex_event: nil,
      turn_count: 0,
      progress: ProgressSignal.initial(),
      started_at: DateTime.utc_now()
    }
  end

  defp seed(pid, issue_id, entry) do
    :sys.replace_state(pid, fn state ->
      state
      |> Map.put(:running, %{issue_id => entry})
      |> Map.put(:claimed, MapSet.new([issue_id]))
    end)
  end

  defp progress(pid, issue_id) do
    :sys.get_state(pid).running[issue_id][:progress]
  end

  describe "claude turn boundaries" do
    test "dirty tree with no commits → at_risk_no_commits, still :progressing (IDE-189)", %{dir: dir} do
      pid = start_orchestrator(:claude_dirty)
      issue = issue("issue-prg-claude")
      seed(pid, issue.id, running_entry(issue, dir, :claude))

      # An uncommitted edit makes the tree dirty for every turn; no commits land.
      File.write!(Path.join(dir, "tracked.txt"), "wip\n")

      for _ <- 1..4 do
        send(pid, {:codex_worker_update, issue.id, claude_turn_completed()})
      end

      # Force a synchronous round-trip so all casts are processed.
      _ = :sys.get_state(pid)

      p = progress(pid, issue.id)
      assert p.turn_count == 4
      assert p.assessment.status == :progressing
      assert p.assessment.at_risk_no_commits
      assert ProgressSignal.trigger?(p.assessment, Config.settings!())

      # snapshot/0 surfaces the assessment for the dashboard / API.
      snap = GenServer.call(pid, :snapshot, 5_000)
      [running] = snap.running
      assert running.progress_assessment.status == :progressing
      assert running.progress_assessment.at_risk_no_commits
    end

    test "clean tree held identical for K turns → :stuck_state", %{dir: dir} do
      pid = start_orchestrator(:claude_stuck)
      issue = issue("issue-prg-stuck")
      seed(pid, issue.id, running_entry(issue, dir, :claude))

      # Tree stays clean (committed initial state) across all turns.
      for _ <- 1..4 do
        send(pid, {:codex_worker_update, issue.id, claude_turn_completed()})
      end

      _ = :sys.get_state(pid)

      assert progress(pid, issue.id).assessment.status == :stuck_state
    end

    test "a commit between turns clears at_risk_no_commits", %{dir: dir} do
      pid = start_orchestrator(:claude_commit)
      issue = issue("issue-prg-commit")
      seed(pid, issue.id, running_entry(issue, dir, :claude))

      # First turn captures the dispatch marker at the initial HEAD.
      send(pid, {:codex_worker_update, issue.id, claude_turn_completed()})
      _ = :sys.get_state(pid)

      # Land a commit, then run more turns past K.
      File.write!(Path.join(dir, "tracked.txt"), "v2\n")
      git!(dir, ["commit", "-aqm", "progress"])

      for _ <- 1..4 do
        send(pid, {:codex_worker_update, issue.id, claude_turn_completed()})
      end

      _ = :sys.get_state(pid)

      p = progress(pid, issue.id)
      assert p.commits_since == 1
      refute p.assessment.at_risk_no_commits
    end
  end

  describe "codex turn boundaries" do
    test "session_started ticks advance the signals", %{dir: dir} do
      pid = start_orchestrator(:codex_dirty)
      issue = issue("issue-prg-codex")
      seed(pid, issue.id, running_entry(issue, dir, :codex))

      File.write!(Path.join(dir, "tracked.txt"), "wip\n")

      for n <- 1..4 do
        send(pid, {:codex_worker_update, issue.id, codex_session_started("sess-#{n}")})
      end

      _ = :sys.get_state(pid)

      p = progress(pid, issue.id)
      assert p.turn_count == 4
      assert p.assessment.at_risk_no_commits
    end
  end

  defp claude_turn_completed do
    %{agent_kind: :claude, event: :turn_completed, timestamp: DateTime.utc_now()}
  end

  defp codex_session_started(session_id) do
    %{event: :session_started, session_id: session_id, timestamp: DateTime.utc_now()}
  end
end
