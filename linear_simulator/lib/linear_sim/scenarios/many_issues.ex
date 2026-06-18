defmodule LinearSim.Scenarios.ManyIssues do
  @moduledoc """
  The base workspace plus 75 Todo issues — more than a default page (50), used
  to exercise pagination behaviour (docs/linear-sim.md §13).
  """
  alias LinearSim.Repo
  alias LinearSim.Linear.Issue
  alias LinearSim.Scenarios.Common

  @issue_count 75

  @doc "Seeds many issues. Must run inside the Scenarios transaction."
  @spec seed!() :: :ok
  def seed! do
    %{org: org, user: user, team: team, states: states, project: project} =
      Common.base_workspace!()

    Enum.each(1..@issue_count, fn n ->
      identifier = "ENG-#{n}"

      Repo.insert!(%Issue{
        id: "issue_eng_#{n}",
        organization_id: org.id,
        team_id: team.id,
        state_id: states.todo.id,
        assignee_id: user.id,
        project_id: project.id,
        identifier: identifier,
        number: n,
        title: "Issue #{n}",
        priority: 2,
        branch_name: Common.branch_name(identifier),
        url: Common.issue_url(identifier)
      })
    end)

    :ok
  end

  @doc "Number of issues this scenario seeds."
  @spec issue_count() :: pos_integer()
  def issue_count, do: @issue_count
end
