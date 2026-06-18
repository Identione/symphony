defmodule LinearSim.Linear do
  @moduledoc """
  Context module for the simulated Linear workspace. Resolvers stay thin and
  call into here (docs/linear-sim.md §16). Grows operation-by-operation.
  """
  import Ecto.Query

  alias LinearSim.Repo

  alias LinearSim.Linear.{
    ApiToken,
    Comment,
    Issue,
    Organization,
    Project,
    Team,
    User,
    WebhookDelivery,
    WorkflowState
  }

  @doc "Coarse entity counts for the current simulator state (dashboard overview)."
  @spec counts() :: %{atom() => non_neg_integer()}
  def counts do
    %{
      organizations: Repo.aggregate(Organization, :count),
      users: Repo.aggregate(User, :count),
      teams: Repo.aggregate(Team, :count),
      projects: Repo.aggregate(Project, :count),
      issues: Repo.aggregate(Issue, :count),
      comments: Repo.aggregate(Comment, :count),
      workflow_states: Repo.aggregate(WorkflowState, :count),
      webhook_deliveries: Repo.aggregate(WebhookDelivery, :count)
    }
  end

  @doc "Lists an organization's users for the entity browser."
  @spec list_users(Organization.t() | nil) :: [User.t()]
  def list_users(nil), do: []

  def list_users(%Organization{} = org) do
    User
    |> where([u], u.organization_id == ^org.id)
    |> order_by([u], asc: u.inserted_at, asc: u.id)
    |> Repo.all()
  end

  @doc "Lists an organization's teams for the entity browser."
  @spec list_teams(Organization.t() | nil) :: [Team.t()]
  def list_teams(nil), do: []

  def list_teams(%Organization{} = org) do
    Team
    |> where([t], t.organization_id == ^org.id)
    |> order_by([t], asc: t.inserted_at, asc: t.id)
    |> Repo.all()
  end

  @doc "Lists every workflow state across an organization's teams (with team preloaded)."
  @spec list_workflow_states(Organization.t() | nil) :: [WorkflowState.t()]
  def list_workflow_states(nil), do: []

  def list_workflow_states(%Organization{} = org) do
    WorkflowState
    |> join(:inner, [s], t in assoc(s, :team))
    |> where([_s, t], t.organization_id == ^org.id)
    |> order_by([s], asc: s.position, asc: s.id)
    |> preload([:team])
    |> Repo.all()
  end

  @doc "Lists recorded webhook delivery attempts, most recent first."
  @spec list_webhook_deliveries() :: [WebhookDelivery.t()]
  def list_webhook_deliveries do
    WebhookDelivery
    |> order_by([d], desc: d.inserted_at, desc: d.id)
    |> Repo.all()
  end

  @doc "The default organization, used when no auth header is supplied."
  @spec default_organization() :: Organization.t() | nil
  def default_organization do
    Organization
    |> order_by(asc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "The default user, used when no auth header is supplied."
  @spec default_user() :: User.t() | nil
  def default_user do
    User
    |> order_by(asc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Resolves a bearer token value into `{user, organization}`.

  Matches an `api_tokens` row by token value first (e.g. `Bearer user_hakan`),
  then falls back to treating the value as a raw user id. Returns `:error` for
  anything unrecognised (§14).
  """
  @spec resolve_token(String.t()) :: {:ok, User.t(), Organization.t()} | :error
  def resolve_token(token) when is_binary(token) do
    case Repo.get_by(ApiToken, token: token) do
      %ApiToken{} = api_token ->
        user = Repo.get(User, api_token.user_id)
        org = Repo.get(Organization, api_token.organization_id)
        if user && org, do: {:ok, user, org}, else: :error

      nil ->
        resolve_user_id(token)
    end
  end

  def resolve_token(_), do: :error

  defp resolve_user_id(value) do
    case Repo.get(User, value) do
      %User{} = user ->
        case Repo.get(Organization, user.organization_id) do
          %Organization{} = org -> {:ok, user, org}
          nil -> :error
        end

      nil ->
        :error
    end
  end

  # Sub-issue fields symphony's poll query reads on each child (state.name/type,
  # assignee.id, labels.nodes.name) and on the parent's children.
  @child_preloads [:state, :assignee, :labels]

  @issue_preloads [
    :state,
    :assignee,
    :team,
    :labels,
    {:children, @child_preloads},
    {:parent, [:state, :assignee, :labels, {:children, @child_preloads}]},
    {:inverse_relations, [issue: :state]}
  ]

  @doc """
  Lists issues for an organization, applying a Linear-style nested filter
  (project.slugId.eq, state.name.in, id.in). Results are deterministically
  ordered by insertion time then id so cursors are stable.
  """
  @spec list_issues(Organization.t() | nil, map()) :: [Issue.t()]
  def list_issues(nil, _filter), do: []

  def list_issues(%Organization{} = org, filter) do
    Issue
    |> where([i], i.organization_id == ^org.id)
    |> apply_issue_filter(filter)
    |> order_by([i], asc: i.inserted_at, asc: i.id)
    |> preload(^@issue_preloads)
    |> Repo.all()
  end

  @doc """
  Fetches a single issue by internal id or ticket identifier (e.g. `ENG-1`),
  scoped to the organization. Returns nil when not found.
  """
  @spec get_issue_by_id_or_identifier(Organization.t() | nil, String.t()) :: Issue.t() | nil
  def get_issue_by_id_or_identifier(nil, _id), do: nil

  def get_issue_by_id_or_identifier(%Organization{} = org, id) do
    Issue
    |> where([i], i.organization_id == ^org.id)
    |> where([i], i.id == ^id or i.identifier == ^id)
    |> preload(^@issue_preloads)
    |> Repo.one()
  end

  @doc "Lists an organization's projects, optionally filtered by exact slug (slugId.eq)."
  @spec list_projects(Organization.t() | nil, map()) :: [Project.t()]
  def list_projects(nil, _filter), do: []

  def list_projects(%Organization{} = org, filter) do
    slug_eq = get_in(filter || %{}, [:slug_id, :eq])

    Project
    |> where([p], p.organization_id == ^org.id)
    |> maybe_filter_slug(slug_eq)
    |> order_by([p], asc: p.inserted_at, asc: p.id)
    |> Repo.all()
  end

  @doc """
  Lists the teams associated with a project. The simulator does not model
  project↔team membership, so this returns every team in the project's
  organization (sufficient for symphony's preflight state-coverage walk).
  """
  @spec list_project_teams(Project.t()) :: [Team.t()]
  def list_project_teams(%Project{} = project) do
    Team
    |> where([t], t.organization_id == ^project.organization_id)
    |> order_by([t], asc: t.inserted_at, asc: t.id)
    |> Repo.all()
  end

  @doc "Lists a team's workflow states, optionally filtered by exact name (name.eq)."
  @spec list_team_states(String.t(), String.t() | nil) :: [WorkflowState.t()]
  def list_team_states(team_id, name_eq \\ nil) do
    WorkflowState
    |> where([s], s.team_id == ^team_id)
    |> maybe_filter_name(name_eq)
    |> order_by([s], asc: s.position, asc: s.id)
    |> Repo.all()
  end

  @doc "Lists an issue's comments, ordered for deterministic pagination."
  @spec list_comments(String.t(), atom()) :: [Comment.t()]
  def list_comments(issue_id, order_by \\ :created_at) do
    Comment
    |> where([c], c.issue_id == ^issue_id)
    |> order_comments(order_by)
    |> Repo.all()
  end

  @doc """
  Creates a comment on an issue. SQLite does not surface FK constraint names, so
  the referenced issue is validated explicitly to yield a clean changeset error
  rather than a raised constraint error.
  """
  @spec create_comment(map()) :: {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def create_comment(attrs) do
    %Comment{}
    |> Comment.changeset(attrs)
    |> validate_issue_exists()
    |> Repo.insert()
  end

  defp validate_issue_exists(changeset) do
    issue_id = Ecto.Changeset.get_field(changeset, :issue_id)

    if is_binary(issue_id) and not Repo.exists?(from(i in Issue, where: i.id == ^issue_id)) do
      Ecto.Changeset.add_error(changeset, :issue_id, "does not reference an existing issue")
    else
      changeset
    end
  end

  @doc "Updates a comment's body."
  @spec update_comment(String.t(), map()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_comment(id, attrs) do
    case Repo.get(Comment, id) do
      nil -> {:error, :not_found}
      comment -> comment |> Comment.changeset(attrs) |> Repo.update()
    end
  end

  @doc "Updates an issue (by internal id or identifier)."
  @spec update_issue(String.t(), map()) ::
          {:ok, Issue.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_issue(id, attrs) do
    query = from i in Issue, where: i.id == ^id or i.identifier == ^id

    case Repo.one(query) do
      nil -> {:error, :not_found}
      issue -> issue |> Issue.changeset(attrs) |> Repo.update()
    end
  end

  defp apply_issue_filter(query, filter) when is_map(filter) do
    query
    |> filter_by_ids(get_in(filter, [:id, :in]))
    |> filter_by_project_slug(get_in(filter, [:project, :slug_id, :eq]))
    |> filter_by_state_names(get_in(filter, [:state, :name, :in]))
  end

  defp apply_issue_filter(query, _), do: query

  defp filter_by_ids(query, nil), do: query
  defp filter_by_ids(query, ids) when is_list(ids), do: where(query, [i], i.id in ^ids)

  defp filter_by_project_slug(query, nil), do: query

  defp filter_by_project_slug(query, slug) do
    query
    |> join(:inner, [i], p in assoc(i, :project))
    |> where([_i, p], p.slug_id == ^slug)
  end

  defp filter_by_state_names(query, nil), do: query

  defp filter_by_state_names(query, names) when is_list(names) do
    query
    |> join(:inner, [i], s in assoc(i, :state))
    |> where([i, ..., s], s.name in ^names)
  end

  defp maybe_filter_name(query, nil), do: query
  defp maybe_filter_name(query, name), do: where(query, [s], s.name == ^name)

  defp maybe_filter_slug(query, nil), do: query
  defp maybe_filter_slug(query, slug), do: where(query, [p], p.slug_id == ^slug)

  defp order_comments(query, :updated_at),
    do: order_by(query, [c], asc: c.updated_at, asc: c.id)

  defp order_comments(query, _),
    do: order_by(query, [c], asc: c.inserted_at, asc: c.id)
end
