defmodule SymphonyElixir.GitTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Git

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-git-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp git!(dir, args) do
    {out, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    String.trim(out)
  end

  defp init_repo_with_commit!(dir) do
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.email", "test@example.com"])
    git!(dir, ["config", "user.name", "Test"])
    File.write!(Path.join(dir, "tracked.txt"), "v1\n")
    git!(dir, ["add", "tracked.txt"])
    git!(dir, ["commit", "-q", "-m", "initial"])
  end

  describe "preserve_uncommitted_work/4" do
    test "captures modified, staged, and untracked files non-destructively", %{dir: dir} do
      init_repo_with_commit!(dir)
      head_before = git!(dir, ["rev-parse", "HEAD"])
      branch_before = git!(dir, ["rev-parse", "--abbrev-ref", "HEAD"])

      # modified tracked file
      File.write!(Path.join(dir, "tracked.txt"), "v2\n")
      # staged new file
      File.write!(Path.join(dir, "staged.txt"), "staged\n")
      git!(dir, ["add", "staged.txt"])
      # untracked new file (the IDE-189 case: a brand-new file)
      File.write!(Path.join(dir, "untracked.txt"), "new work\n")

      assert {:ok, {:preserved, sha, ref}} =
               Git.preserve_uncommitted_work(dir, "IDE-189")

      assert ref == "refs/symphony/wip/ide-189"

      # The WIP commit contains all three files.
      tree = git!(dir, ["ls-tree", "-r", "--name-only", sha])
      assert tree =~ "tracked.txt"
      assert tree =~ "staged.txt"
      assert tree =~ "untracked.txt"

      # And the modified tracked file carries the dirty content, not HEAD's.
      assert "v2" == git!(dir, ["show", "#{sha}:tracked.txt"]) |> String.trim()

      # Non-destructive: HEAD, branch, and working tree are unchanged.
      assert git!(dir, ["rev-parse", "HEAD"]) == head_before
      assert git!(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) == branch_before
      refute git!(dir, ["status", "--porcelain"]) == ""
      assert git!(dir, ["rev-parse", ref]) == sha
    end

    test "is a no-op on a clean tree", %{dir: dir} do
      init_repo_with_commit!(dir)

      assert {:ok, :clean} = Git.preserve_uncommitted_work(dir, "IDE-189")

      assert {_, status} =
               System.cmd("git", ["rev-parse", "refs/symphony/wip/ide-189"],
                 cd: dir,
                 stderr_to_stdout: true
               )

      assert status != 0
    end

    test "returns :not_a_git_repo for a non-git directory", %{dir: dir} do
      assert {:error, :not_a_git_repo} = Git.preserve_uncommitted_work(dir, "IDE-189")
    end

    test "creates a visible branch when branch: true", %{dir: dir} do
      init_repo_with_commit!(dir)
      File.write!(Path.join(dir, "untracked.txt"), "new\n")

      assert {:ok, {:preserved, sha, _ref}} =
               Git.preserve_uncommitted_work(dir, "IDE-189", nil, branch: true)

      assert git!(dir, ["rev-parse", "refs/heads/symphony/wip/ide-189"]) == sha
    end

    test "preserves work in a repo with no commits yet (HEAD-less)", %{dir: dir} do
      git!(dir, ["init", "-q"])
      git!(dir, ["config", "user.email", "test@example.com"])
      git!(dir, ["config", "user.name", "Test"])
      File.write!(Path.join(dir, "first.txt"), "content\n")

      assert {:ok, {:preserved, sha, ref}} =
               Git.preserve_uncommitted_work(dir, "IDE-189")

      assert git!(dir, ["ls-tree", "-r", "--name-only", sha]) =~ "first.txt"
      assert git!(dir, ["rev-parse", ref]) == sha
    end

    test "sanitizes the issue identifier into the ref name", %{dir: dir} do
      init_repo_with_commit!(dir)
      File.write!(Path.join(dir, "x.txt"), "x\n")

      assert {:ok, {:preserved, _sha, ref}} =
               Git.preserve_uncommitted_work(dir, "Feature/AB 12")

      assert ref == "refs/symphony/wip/feature/ab_12"
    end
  end

  describe "working_tree_signals/4 (IDE-211 Layer 1 probe)" do
    test "reports an empty/clean tree with no commits since the marker", %{dir: dir} do
      init_repo_with_commit!(dir)
      head = git!(dir, ["rev-parse", "HEAD"])

      assert {:ok, signals} = Git.working_tree_signals(dir, head)
      assert signals.empty
      assert signals.commits_since == 0
      assert signals.head == head
      assert String.match?(signals.hash, ~r/^[0-9a-f]{40}$/)
    end

    test "a dirty tree is non-empty and the hash captures untracked files", %{dir: dir} do
      init_repo_with_commit!(dir)
      {:ok, clean} = Git.working_tree_signals(dir, nil)

      # The IDE-189 case: a brand-new untracked file must change the hash.
      File.write!(Path.join(dir, "untracked.txt"), "new work\n")
      {:ok, dirty} = Git.working_tree_signals(dir, nil)

      refute dirty.empty
      refute dirty.hash == clean.hash
    end

    test "identical content across probes yields a stable hash", %{dir: dir} do
      init_repo_with_commit!(dir)
      File.write!(Path.join(dir, "wip.txt"), "same\n")

      {:ok, a} = Git.working_tree_signals(dir, nil)
      {:ok, b} = Git.working_tree_signals(dir, nil)
      assert a.hash == b.hash
    end

    test "counts commits made since the dispatch marker", %{dir: dir} do
      init_repo_with_commit!(dir)
      marker = git!(dir, ["rev-parse", "HEAD"])

      File.write!(Path.join(dir, "a.txt"), "a\n")
      git!(dir, ["add", "a.txt"])
      git!(dir, ["commit", "-q", "-m", "second"])
      File.write!(Path.join(dir, "b.txt"), "b\n")
      git!(dir, ["add", "b.txt"])
      git!(dir, ["commit", "-q", "-m", "third"])

      assert {:ok, %{commits_since: 2}} = Git.working_tree_signals(dir, marker)
    end

    test "is non-destructive: HEAD, branch, and status are untouched", %{dir: dir} do
      init_repo_with_commit!(dir)
      File.write!(Path.join(dir, "tracked.txt"), "v2\n")
      File.write!(Path.join(dir, "untracked.txt"), "new\n")
      head_before = git!(dir, ["rev-parse", "HEAD"])
      status_before = git!(dir, ["status", "--porcelain"])

      assert {:ok, _signals} = Git.working_tree_signals(dir, head_before)

      assert git!(dir, ["rev-parse", "HEAD"]) == head_before
      assert git!(dir, ["status", "--porcelain"]) == status_before
    end

    test "errors on a non-git directory", %{dir: dir} do
      assert {:error, :not_a_git_repo} = Git.working_tree_signals(dir, nil)
    end
  end
end
