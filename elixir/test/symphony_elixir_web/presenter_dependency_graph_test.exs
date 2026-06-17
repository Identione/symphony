defmodule SymphonyElixirWeb.PresenterDependencyGraphTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Orchestrator
  alias SymphonyElixirWeb.Presenter

  @container_id "parent-1"
  @managed_child_id "child-managed"
  @unmanaged_child_id "child-unmanaged"

  # Seeds an orchestrator whose dependency_graph already holds a container
  # (parent/umbrella) node with one managed and one unmanaged sub-issue, then
  # projects it through the presenter exactly as the dashboard does.
  defp graph_payload do
    name = Module.concat(__MODULE__, :Orchestrator)
    {:ok, pid} = Orchestrator.start_link(name: name, poll_on_start: false)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    graph = %{
      @container_id => %{
        id: @container_id,
        identifier: "MT-1",
        title: "Umbrella",
        state: "In Progress",
        state_type: "started",
        priority: nil,
        url: "https://linear.app/example/MT-1",
        blocked_by: [],
        placeholder: false,
        kind: :container,
        parent: nil,
        child_total: 2,
        child_done: 1
      },
      @managed_child_id => %{
        id: @managed_child_id,
        identifier: "MT-2",
        title: "Managed sub-issue",
        state: "Todo",
        state_type: "unstarted",
        priority: 2,
        url: "https://linear.app/example/MT-2",
        blocked_by: [],
        placeholder: false,
        kind: :issue,
        parent: @container_id,
        managed: true,
        requirements: []
      },
      @unmanaged_child_id => %{
        id: @unmanaged_child_id,
        identifier: "MT-3",
        title: "Unmanaged sub-issue",
        state: "Backlog",
        state_type: "backlog",
        priority: 3,
        url: "https://linear.app/example/MT-3",
        blocked_by: [],
        placeholder: false,
        kind: :issue,
        parent: @container_id,
        managed: false,
        requirements: ["add label(s): agent", "move to an active state (Todo, In Progress)"]
      }
    }

    :sys.replace_state(pid, fn state -> Map.put(state, :dependency_graph, graph) end)

    Presenter.state_payload(name, 5_000).dependency_graph
  end

  defp node(nodes, id), do: Enum.find(nodes, &(&1.id == id))

  test "serializes a container node with aggregate sub-issue progress" do
    container = graph_payload().nodes |> node(@container_id)

    assert container.kind == "container"
    assert container.parent == nil
    assert container.child_total == 2
    assert container.child_done == 1
    # Containers summarize progress rather than a dispatch session.
    assert container.inactive_reason == "1/2 sub-issues done"
  end

  test "tags a managed sub-issue with its container and managed=true" do
    managed = graph_payload().nodes |> node(@managed_child_id)

    assert managed.kind == "issue"
    assert managed.parent == @container_id
    assert managed.managed == true
    assert managed.requirements == []
  end

  test "tags an unmanaged sub-issue with what must change to manage it" do
    unmanaged = graph_payload().nodes |> node(@unmanaged_child_id)

    assert unmanaged.kind == "issue"
    assert unmanaged.parent == @container_id
    assert unmanaged.managed == false
    assert "add label(s): agent" in unmanaged.requirements
    assert unmanaged.inactive_reason =~ "Needs:"
    assert unmanaged.inactive_reason =~ "add label(s): agent"
  end
end
