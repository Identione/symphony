defmodule LinearSim.ScenariosTest do
  use LinearSim.DataCase, async: false

  alias LinearSim.Linear.{Issue, Organization, WorkflowState}
  alias LinearSim.Scenarios

  describe "load!/1" do
    test "basic_workspace seeds a deterministic org, states and one issue" do
      :ok = Scenarios.load!("basic_workspace")

      assert %Organization{name: "Acme"} = Repo.get(Organization, "org_default")
      assert Repo.aggregate(Issue, :count) == 1

      assert %Issue{identifier: "ENG-1", branch_name: branch, url: url} =
               Repo.get(Issue, "issue_eng_1")

      assert is_binary(branch)
      assert is_binary(url)
      # The full IDE-team workflow states are present (mirrors real Linear).
      assert Repo.aggregate(WorkflowState, :count) == 10
    end

    test "empty_workspace seeds the skeleton but no issues" do
      :ok = Scenarios.load!("empty_workspace")

      assert Repo.get(Organization, "org_default")
      assert Repo.aggregate(Issue, :count) == 0
    end

    test "many_issues seeds more than one page of issues" do
      :ok = Scenarios.load!("many_issues")

      assert Repo.aggregate(Issue, :count) == LinearSim.Scenarios.ManyIssues.issue_count()
      assert Repo.aggregate(Issue, :count) > 50
    end

    test "reloading wipes prior state (repeatable)" do
      :ok = Scenarios.load!("many_issues")
      assert Repo.aggregate(Issue, :count) > 1

      :ok = Scenarios.load!("basic_workspace")
      assert Repo.aggregate(Issue, :count) == 1
    end
  end

  describe "load/1" do
    test "returns an error for an unknown scenario" do
      assert {:error, :unknown_scenario} = Scenarios.load("nope")
    end
  end
end
