defmodule LinearSim.WorkflowStatesTest do
  @moduledoc """
  The simulator's seeded workflow states must mirror the real Linear workspace
  (team IDE) — same names, types, and colors — so Symphony sees a faithful board.
  Colors were fetched live from the Linear API (workflowStates.color).
  """
  use LinearSim.DataCase, async: false

  alias LinearSim.Linear

  # name => {type, color} — exactly the IDE team's states in real Linear.
  @expected %{
    "Backlog" => {"backlog", "#bec2c8"},
    "Todo" => {"unstarted", "#e2e2e2"},
    "In Progress" => {"started", "#f2c94c"},
    "In Review" => {"started", "#0f783c"},
    "Human Review" => {"started", "#4cb782"},
    "Rework" => {"started", "#4cb782"},
    "Merging" => {"started", "#4cb782"},
    "Done" => {"completed", "#5e6ad2"},
    "Canceled" => {"canceled", "#95a2b3"},
    "Duplicate" => {"duplicate", "#95a2b3"}
  }

  test "seeds the same workflow states as the real Linear IDE team" do
    org = Linear.default_organization()

    actual =
      org
      |> Linear.list_workflow_states()
      |> Map.new(&{&1.name, {&1.type, &1.color}})

    assert actual == @expected
  end
end
