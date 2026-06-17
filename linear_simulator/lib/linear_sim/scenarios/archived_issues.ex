defmodule LinearSim.Scenarios.ArchivedIssues do
  @moduledoc """
  The base workspace plus one active Todo issue and one archived (Done) issue,
  so tests can assert that archived issues are filtered/handled correctly.
  """
  alias LinearSim.Repo
  alias LinearSim.Linear.Issue
  alias LinearSim.Scenarios.Common

  @doc "Seeds active and archived issues. Must run inside the Scenarios transaction."
  @spec seed!() :: :ok
  def seed! do
    %{org: org, user: user, team: team, states: states, project: project} =
      Common.base_workspace!()

    Repo.insert!(%Issue{
      id: "issue_eng_1",
      organization_id: org.id,
      team_id: team.id,
      state_id: states.todo.id,
      assignee_id: user.id,
      project_id: project.id,
      identifier: "ENG-1",
      number: 1,
      title: "Active issue",
      priority: 2,
      branch_name: Common.branch_name("ENG-1"),
      url: Common.issue_url("ENG-1")
    })

    Repo.insert!(%Issue{
      id: "issue_eng_2",
      organization_id: org.id,
      team_id: team.id,
      state_id: states.done.id,
      assignee_id: user.id,
      project_id: project.id,
      identifier: "ENG-2",
      number: 2,
      title: "Archived issue",
      priority: 3,
      branch_name: Common.branch_name("ENG-2"),
      url: Common.issue_url("ENG-2"),
      archived_at: ~U[2026-01-01 00:00:00.000000Z]
    })

    :ok
  end
end
