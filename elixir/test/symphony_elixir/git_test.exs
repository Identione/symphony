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

  describe "working_tree_probe/4" do
    test "reports an empty tree with a stable hash and HEAD", %{dir: dir} do
      init_repo_with_commit!(dir)
      head = git!(dir, ["rev-parse", "HEAD"])

      assert {:ok, probe} = Git.working_tree_probe(dir)
      assert probe.empty
      assert probe.head == head
      assert probe.commits_since == 0
      assert is_binary(probe.hash) and byte_size(probe.hash) == 64

      # Repeating on the same clean tree yields the same hash.
      assert {:ok, again} = Git.working_tree_probe(dir)
      assert again.hash == probe.hash
    end

    test "a modified tracked file flips empty=false and changes the hash", %{dir: dir} do
      init_repo_with_commit!(dir)
      assert {:ok, clean} = Git.working_tree_probe(dir)

      File.write!(Path.join(dir, "tracked.txt"), "v2\n")
      assert {:ok, dirty} = Git.working_tree_probe(dir)

      refute dirty.empty
      assert dirty.hash != clean.hash
    end

    test "an untracked file also makes the tree dirty", %{dir: dir} do
      init_repo_with_commit!(dir)
      File.write!(Path.join(dir, "new.txt"), "x\n")

      assert {:ok, probe} = Git.working_tree_probe(dir)
      refute probe.empty
    end

    test "counts commits since a marker", %{dir: dir} do
      init_repo_with_commit!(dir)
      marker = git!(dir, ["rev-parse", "HEAD"])

      File.write!(Path.join(dir, "tracked.txt"), "v2\n")
      git!(dir, ["commit", "-aqm", "second"])
      File.write!(Path.join(dir, "tracked.txt"), "v3\n")
      git!(dir, ["commit", "-aqm", "third"])

      assert {:ok, probe} = Git.working_tree_probe(dir, marker)
      assert probe.commits_since == 2
      assert probe.empty
    end

    test "returns :not_a_git_repo for a non-git directory", %{dir: dir} do
      assert {:error, :not_a_git_repo} = Git.working_tree_probe(dir)
    end
  end
end
