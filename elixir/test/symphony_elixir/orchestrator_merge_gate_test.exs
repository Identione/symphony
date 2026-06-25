defmodule SymphonyElixir.OrchestratorMergeGateTest do
  @moduledoc """
  Behavioral coverage for the merge-gate dependency-resume hold (IDE-233, §8.2).

  Drives `resolve_rebase_merge_status/2` and the dispatch gate
  (`should_dispatch_issue?/4`) through the in-memory `SymphonyElixir.GitHost`
  adapter so no real `gh`/GitHub is needed. Each test seeds a `rebase_pending`
  entry (an issue paused mid-run by a now-Linear-terminal blocker) and asserts
  whether the merge-gate holds or releases it, plus the `awaiting_merge`
  observability mirror that backs the Admin UI.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Orchestrator

  @blocker_pr "https://github.com/Identione/symphony/pull/42"

  setup do
    write_workflow_file!(Workflow.workflow_file_path(), tracker_kind: "memory", tracker_api_token: nil)
    if Process.whereis(SymphonyElixir.WorkflowStore), do: SymphonyElixir.WorkflowStore.force_reload()

    Application.put_env(:symphony_elixir, :git_host_adapter, SymphonyElixir.GitHost.Memory)
    Application.put_env(:symphony_elixir, :memory_git_host_gate_active, true)

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :git_host_adapter)
      Application.delete_env(:symphony_elixir, :memory_git_host_gate_active)
      Application.delete_env(:symphony_elixir, :memory_git_host_pr_merged)
      Application.delete_env(:symphony_elixir, :memory_git_host_default)
    end)

    :ok
  end

  defp issue(id, identifier, blocked_by) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "Title #{identifier}",
      state: "In Progress",
      url: "https://example.org/issues/#{identifier}",
      labels: [],
      blocked_by: blocked_by,
      assigned_to_worker: true
    }
  end

  defp done_blocker(identifier, pr_url) do
    %{id: "blk-#{identifier}", identifier: identifier, state: "Done", pr_url: pr_url}
  end

  defp state_with_rebase_pending(issue_id) do
    %Orchestrator.State{
      running: %{},
      claimed: MapSet.new(),
      blocked: %{},
      max_concurrent_agents: 10,
      rebase_pending: %{issue_id => %{blockers: [%{identifier: "BLK", pr_url: @blocker_pr}]}}
    }
  end

  defp set_pr_merged(map) do
    Application.put_env(:symphony_elixir, :memory_git_host_pr_merged, map)
  end

  test "blocker PR still open holds the issue with :pr_open and surfaces it in awaiting_merge" do
    iss = issue("iss-open", "OPEN-1", [done_blocker("BLK", @blocker_pr)])
    set_pr_merged(%{@blocker_pr => {:ok, false}})

    state =
      Orchestrator.resolve_rebase_merge_status_for_test(state_with_rebase_pending(iss.id), [iss])

    assert %{reason: :pr_open, blocker_prs: [@blocker_pr]} = Map.get(state.awaiting_merge, iss.id)
    refute MapSet.member?(state.merge_landed, iss.id)
    refute Orchestrator.should_dispatch_issue_for_test(iss, state)
  end

  test "all blocker PRs merged releases the issue and caches it as landed" do
    iss = issue("iss-merged", "MERGED-1", [done_blocker("BLK", @blocker_pr)])
    set_pr_merged(%{@blocker_pr => {:ok, true}})

    state =
      Orchestrator.resolve_rebase_merge_status_for_test(state_with_rebase_pending(iss.id), [iss])

    refute Map.has_key?(state.awaiting_merge, iss.id)
    assert MapSet.member?(state.merge_landed, iss.id)
    assert Orchestrator.should_dispatch_issue_for_test(iss, state)
  end

  test "a Linear-terminal blocker with no linked PR holds with :no_pr_attachment" do
    iss = issue("iss-nopr", "NOPR-1", [done_blocker("BLK", nil)])

    state =
      Orchestrator.resolve_rebase_merge_status_for_test(state_with_rebase_pending(iss.id), [iss])

    assert %{reason: :no_pr_attachment} = Map.get(state.awaiting_merge, iss.id)
    refute Orchestrator.should_dispatch_issue_for_test(iss, state)
  end

  test "a gh lookup error holds with :check_error rather than releasing" do
    iss = issue("iss-err", "ERR-1", [done_blocker("BLK", @blocker_pr)])
    set_pr_merged(%{@blocker_pr => {:error, :gh_timeout}})

    state =
      Orchestrator.resolve_rebase_merge_status_for_test(state_with_rebase_pending(iss.id), [iss])

    assert %{reason: :check_error} = Map.get(state.awaiting_merge, iss.id)
    refute Orchestrator.should_dispatch_issue_for_test(iss, state)
  end

  test "an inactive gate never holds even when the blocker PR is unmerged" do
    Application.put_env(:symphony_elixir, :memory_git_host_gate_active, false)
    iss = issue("iss-inactive", "INACTIVE-1", [done_blocker("BLK", @blocker_pr)])
    set_pr_merged(%{@blocker_pr => {:ok, false}})

    state =
      Orchestrator.resolve_rebase_merge_status_for_test(state_with_rebase_pending(iss.id), [iss])

    assert state.awaiting_merge == %{}
    assert Orchestrator.should_dispatch_issue_for_test(iss, state)
  end

  test "a still-non-terminal Linear blocker is left to the dependency-blocked path, not the merge gate" do
    open_blocker = %{id: "blk-open", identifier: "BLK", state: "In Progress", pr_url: @blocker_pr}
    iss = issue("iss-nonterminal", "NONTERM-1", [open_blocker])
    set_pr_merged(%{@blocker_pr => {:ok, false}})

    state =
      Orchestrator.resolve_rebase_merge_status_for_test(state_with_rebase_pending(iss.id), [iss])

    assert state.awaiting_merge == %{}
  end

  test "observed_at is preserved across resolve passes for a stable holding-since timestamp" do
    iss = issue("iss-stable", "STABLE-1", [done_blocker("BLK", @blocker_pr)])
    set_pr_merged(%{@blocker_pr => {:ok, false}})

    state1 =
      Orchestrator.resolve_rebase_merge_status_for_test(state_with_rebase_pending(iss.id), [iss])

    first_observed = Map.get(state1.awaiting_merge, iss.id).observed_at

    state2 = Orchestrator.resolve_rebase_merge_status_for_test(state1, [iss])

    assert Map.get(state2.awaiting_merge, iss.id).observed_at == first_observed
  end

  test "merge_landed is pruned to the live rebase_pending key set each pass" do
    iss = issue("iss-prune", "PRUNE-1", [done_blocker("BLK", @blocker_pr)])
    set_pr_merged(%{@blocker_pr => {:ok, true}})

    base = state_with_rebase_pending(iss.id)
    stale = %{base | merge_landed: MapSet.new([iss.id, "iss-gone"])}

    state = Orchestrator.resolve_rebase_merge_status_for_test(stale, [iss])

    assert MapSet.member?(state.merge_landed, iss.id)
    refute MapSet.member?(state.merge_landed, "iss-gone")
  end
end
