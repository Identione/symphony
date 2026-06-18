defmodule LinearSim.Scenarios.Common do
  @moduledoc """
  Shared seed building blocks. Deterministic string IDs throughout so fixtures
  and assertions stay stable (docs/linear-sim.md §7).
  """
  alias LinearSim.Repo

  alias LinearSim.Linear.{
    ApiToken,
    Label,
    Organization,
    Project,
    Team,
    User,
    WorkflowState
  }

  @doc """
  Seeds the standard org/user/token/team/states/project skeleton used by most
  scenarios. Returns a map of the inserted records for issue seeding.
  """
  @spec base_workspace!() :: map()
  def base_workspace! do
    org = Repo.insert!(%Organization{id: "org_default", name: "Acme", url_key: "acme"})

    user =
      Repo.insert!(%User{
        id: "user_hakan",
        organization_id: org.id,
        name: "Håkan Niska",
        email: "hakan@example.test"
      })

    # Token value matches the user id so `Authorization: Bearer user_hakan`
    # works directly (§14), and a separate opaque token is also resolvable.
    Repo.insert!(%ApiToken{
      id: "token_hakan",
      organization_id: org.id,
      user_id: user.id,
      token: "user_hakan",
      label: "Default simulator token"
    })

    team =
      Repo.insert!(%Team{
        id: "team_eng",
        organization_id: org.id,
        key: "ENG",
        name: "Engineering"
      })

    # The full set of workflow states symphony's default workflow references
    # (active: Todo/In Progress/Merging/Rework; terminal: Canceled/Duplicate/Done),
    # plus In Review. Keeps `make preflight` state-coverage green out of the box.
    states = %{
      todo: insert_state!(team, "state_todo", "Todo", "unstarted", 1),
      in_progress: insert_state!(team, "state_in_progress", "In Progress", "started", 2),
      in_review: insert_state!(team, "state_in_review", "In Review", "started", 3),
      merging: insert_state!(team, "state_merging", "Merging", "started", 4),
      rework: insert_state!(team, "state_rework", "Rework", "started", 5),
      done: insert_state!(team, "state_done", "Done", "completed", 6),
      canceled: insert_state!(team, "state_canceled", "Canceled", "canceled", 7),
      duplicate: insert_state!(team, "state_duplicate", "Duplicate", "canceled", 8)
    }

    project =
      Repo.insert!(%Project{
        id: "project_roadmap",
        organization_id: org.id,
        name: "Roadmap",
        slug_id: "roadmap"
      })

    # A small set of workspace labels so issueAddLabel / labelIds have something
    # to attach out of the box (deterministic ids for fixtures and assertions).
    labels = %{
      bug: insert_label!(org, "label_bug", "Bug", "#e5484d"),
      feature: insert_label!(org, "label_feature", "Feature", "#4c6ef5"),
      improvement: insert_label!(org, "label_improvement", "Improvement", "#2f9e44")
    }

    %{org: org, user: user, team: team, states: states, project: project, labels: labels}
  end

  @doc "Inserts a workspace label for the given organization."
  @spec insert_label!(struct(), String.t(), String.t(), String.t()) :: struct()
  def insert_label!(org, id, name, color) do
    Repo.insert!(%Label{id: id, organization_id: org.id, name: name, color: color})
  end

  @doc "Inserts a workflow state for the given team."
  @spec insert_state!(struct(), String.t(), String.t(), String.t(), integer()) :: struct()
  def insert_state!(team, id, name, type, position) do
    Repo.insert!(%WorkflowState{
      id: id,
      team_id: team.id,
      name: name,
      type: type,
      position: position
    })
  end

  @doc "Builds a Linear-style issue URL for the given identifier."
  @spec issue_url(String.t()) :: String.t()
  def issue_url(identifier) do
    "https://linear.app/acme/issue/#{identifier}"
  end

  @doc "Builds a Linear-style branch name for the given identifier."
  @spec branch_name(String.t()) :: String.t()
  def branch_name(identifier) do
    "hakan/#{String.downcase(identifier)}"
  end
end
