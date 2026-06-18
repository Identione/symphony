defmodule SymphonyElixir.ParentAutoCompleteTest do
  @moduledoc """
  Covers auto-completing a parent/umbrella issue once every one of its
  sub-issues is Done (see
  `Orchestrator.complete_parents_with_all_children_done/2`).

  The memory tracker is configured as the active adapter so the orchestrator's
  `Tracker.update_issue_state/2` calls land as `{:memory_tracker_state_update,
  issue_id, state_name}` messages on the test process.
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue

  setup do
    # Swap the tracker kind to "memory" so state-update calls land on the test
    # process via memory_tracker_recipient.
    path = Workflow.workflow_file_path()
    content = File.read!(path)
    File.write!(path, String.replace(content, ~s(kind: "linear"), ~s(kind: "memory")))

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      SymphonyElixir.WorkflowStore.force_reload()
    end

    Application.put_env(:symphony_elixir, :memory_tracker_recipient, self())

    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :memory_tracker_recipient)
    end)

    :ok
  end

  defp child(id, state) do
    %Issue{id: id, identifier: id, title: id, state: state}
  end

  defp parent(children, opts \\ []) do
    %Issue{
      id: "parent-1",
      identifier: "UMB-1",
      title: "Umbrella",
      state: Keyword.get(opts, :state, "In Progress"),
      has_children: true,
      children: children
    }
  end

  defp run(issues) do
    Orchestrator.complete_parents_with_all_children_done_for_test(issues, %Orchestrator.State{})
  end

  test "moves the parent to Done when every sub-issue is Done" do
    issues = [parent([child("c1", "Done"), child("c2", "Done")])]

    run(issues)

    assert_receive {:memory_tracker_state_update, "parent-1", "Done"}, 1_000
  end

  test "leaves the parent untouched when a sub-issue is not yet Done" do
    issues = [parent([child("c1", "Done"), child("c2", "In Progress")])]

    run(issues)

    refute_received {:memory_tracker_state_update, _, _}
  end

  test "treats a cancelled sub-issue as not-Done (strict Done semantics)" do
    issues = [parent([child("c1", "Done"), child("c2", "Cancelled")])]

    run(issues)

    refute_received {:memory_tracker_state_update, _, _}
  end

  test "does not resurrect a parent that is itself already terminal" do
    issues = [parent([child("c1", "Done")], state: "Done")]

    run(issues)

    refute_received {:memory_tracker_state_update, _, _}
  end

  test "ignores an issue with no sub-issues" do
    issues = [%Issue{id: "leaf-1", identifier: "LEAF-1", state: "In Progress", has_children: false}]

    run(issues)

    refute_received {:memory_tracker_state_update, _, _}
  end

  test "ignores a parent whose children list is empty" do
    issues = [parent([])]

    run(issues)

    refute_received {:memory_tracker_state_update, _, _}
  end

  test "skips a parent whose child list is at the fetch cap (possible truncation)" do
    children = for n <- 1..50, do: child("c#{n}", "Done")
    issues = [parent(children)]

    run(issues)

    refute_received {:memory_tracker_state_update, _, _}
  end

  test "completes only the eligible parent among several issues" do
    done_parent = parent([child("a1", "Done"), child("a2", "Done")])

    pending_parent = %Issue{
      id: "parent-2",
      identifier: "UMB-2",
      title: "Other umbrella",
      state: "In Progress",
      has_children: true,
      children: [child("b1", "Done"), child("b2", "Todo")]
    }

    run([done_parent, pending_parent])

    assert_receive {:memory_tracker_state_update, "parent-1", "Done"}, 1_000
    refute_received {:memory_tracker_state_update, "parent-2", _}
  end
end
