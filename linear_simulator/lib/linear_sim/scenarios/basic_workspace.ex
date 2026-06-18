defmodule LinearSim.Scenarios.BasicWorkspace do
  @moduledoc """
  The default scenario: one org, one user, one team with the standard workflow
  states, one project, and a single Todo issue ready to be polled by symphony.
  """
  alias LinearSim.Repo
  alias LinearSim.Linear.{Comment, Issue}
  alias LinearSim.Scenarios.Common

  @doc "Seeds the basic workspace. Must run inside the Scenarios transaction."
  @spec seed!() :: :ok
  def seed! do
    %{org: org, user: user, team: team, states: states, project: project} =
      Common.base_workspace!()

    issue =
      Repo.insert!(%Issue{
        id: "issue_eng_1",
        organization_id: org.id,
        team_id: team.id,
        state_id: states.todo.id,
        assignee_id: user.id,
        project_id: project.id,
        identifier: "ENG-1",
        number: 1,
        title: "Build Linear simulator",
        description: "Initial simulator issue",
        priority: 2,
        branch_name: Common.branch_name("ENG-1"),
        url: Common.issue_url("ENG-1")
      })

    # A deterministic seeded comment carrying the workpad marker symphony's
    # escalation path searches for, and giving commentUpdate a stable id.
    Repo.insert!(%Comment{
      id: "comment_eng_1_workpad",
      issue_id: issue.id,
      user_id: user.id,
      body: "## Symphony Workpad\n\n(seeded)"
    })

    :ok
  end
end
