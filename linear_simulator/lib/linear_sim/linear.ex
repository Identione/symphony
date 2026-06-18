defmodule LinearSim.Linear do
  @moduledoc """
  Context module for the simulated Linear workspace. Resolvers stay thin and
  call into here (docs/linear-sim.md §16). Grows operation-by-operation.
  """
  import Ecto.Query

  alias LinearSim.Repo

  alias LinearSim.Linear.{
    ApiToken,
    Attachment,
    Comment,
    Cycle,
    Issue,
    IssueLabel,
    IssueRelation,
    Label,
    Organization,
    Project,
    Team,
    User,
    WebhookDelivery,
    WorkflowState
  }

  # FK fields validated explicitly before insert/update: SQLite doesn't surface
  # constraint names, so a bad reference would otherwise raise instead of
  # yielding a clean changeset error (same approach as create_comment).
  @issue_fk_checks [
    {:state_id, WorkflowState},
    {:assignee_id, User},
    {:project_id, Project},
    {:parent_id, Issue},
    {:cycle_id, Cycle}
  ]

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
  def list_workflow_states(org), do: list_workflow_states(org, %{})

  @doc """
  Lists workflow states across an organization's teams, applying a Linear-style
  `WorkflowStateFilter` (`team.key.eq`, `team.id.eq`, `name.eq`). Team is preloaded.
  """
  @spec list_workflow_states(Organization.t() | nil, map()) :: [WorkflowState.t()]
  def list_workflow_states(nil, _filter), do: []

  def list_workflow_states(%Organization{} = org, filter) do
    WorkflowState
    |> join(:inner, [s], t in assoc(s, :team))
    |> where([_s, t], t.organization_id == ^org.id)
    |> filter_states_by_team(
      get_in(filter, [:team, :key, :eq]),
      get_in(filter, [:team, :id, :eq])
    )
    |> maybe_filter_name(get_in(filter, [:name, :eq]))
    |> order_by([s], asc: s.position, asc: s.id)
    |> preload([:team])
    |> Repo.all()
  end

  defp filter_states_by_team(query, nil, nil), do: query

  defp filter_states_by_team(query, key, _id) when is_binary(key),
    do: where(query, [_s, t], t.key == ^key)

  defp filter_states_by_team(query, _key, id) when is_binary(id),
    do: where(query, [s, _t], s.team_id == ^id)

  @doc "Fetches a team within an organization by internal id or team key (e.g. `ENG`)."
  @spec get_team(Organization.t() | nil, String.t()) :: Team.t() | nil
  def get_team(nil, _id_or_key), do: nil

  def get_team(%Organization{} = org, id_or_key) when is_binary(id_or_key) do
    Team
    |> where([t], t.organization_id == ^org.id)
    |> where([t], t.id == ^id_or_key or t.key == ^id_or_key)
    |> Repo.one()
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
    :project,
    :labels,
    {:children, @child_preloads},
    {:parent, [:state, :assignee, :labels, {:children, @child_preloads}]},
    relations: [issue: :state, related_issue: :state],
    inverse_relations: [issue: :state, related_issue: :state]
  ]

  @doc """
  Lists issues for an organization, applying a Linear-style nested filter
  (project.slugId.eq, state.name.in, id.in). Archived issues are excluded by
  default (matching Linear's `issues` query). Results are deterministically
  ordered by insertion time then id so cursors are stable.
  """
  @spec list_issues(Organization.t() | nil, map()) :: [Issue.t()]
  def list_issues(nil, _filter), do: []

  def list_issues(%Organization{} = org, filter) do
    Issue
    |> where([i], i.organization_id == ^org.id)
    |> where([i], is_nil(i.archived_at))
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
  Fetches a single project by internal id or slug, scoped to the organization.
  Mirrors Linear's `project(id:)`; lenient on slug for the simulator's stable
  string ids. Returns nil when not found.
  """
  @spec get_project_by_id_or_slug(Organization.t() | nil, String.t()) :: Project.t() | nil
  def get_project_by_id_or_slug(nil, _id), do: nil

  def get_project_by_id_or_slug(%Organization{} = org, id) do
    Project
    |> where([p], p.organization_id == ^org.id)
    |> where([p], p.id == ^id or p.slug_id == ^id)
    |> Repo.one()
  end

  @doc """
  Lists a project's issues (deterministically ordered, archived excluded, with
  the same preloads as `list_issues` so nested GraphQL fields resolve).
  """
  @spec list_project_issues(Project.t()) :: [Issue.t()]
  def list_project_issues(%Project{} = project) do
    Issue
    |> where([i], i.project_id == ^project.id)
    |> where([i], is_nil(i.archived_at))
    |> order_by([i], asc: i.inserted_at, asc: i.id)
    |> preload(^@issue_preloads)
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
    |> preload([:user])
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

  @doc """
  Updates an issue (by internal id or identifier). Accepts scalar/FK fields
  (`title`, `description`, `priority`, `state_id`, `assignee_id`, `project_id`,
  `parent_id`, `cycle_id`) plus label operations: `label_ids` (full replace),
  `added_label_ids`, and `removed_label_ids` (incremental), mirroring Linear's
  `IssueUpdateInput`. Keys may be atoms or strings.
  """
  @spec update_issue(String.t(), map()) ::
          {:ok, Issue.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_issue(id, attrs) do
    attrs = normalize_attrs(attrs)

    case fetch_issue(id) do
      nil ->
        {:error, :not_found}

      issue ->
        case issue |> Issue.changeset(attrs) |> validate_issue_references() |> Repo.update() do
          {:ok, updated} ->
            apply_label_ops(updated.id, attrs)
            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc """
  Creates a new issue in the organization, auto-assigning the internal id and
  the per-team `number`/`identifier`/`url`/`branch_name`. The caller supplies
  the editable fields (`team_id`, `title`, and optionally `description`,
  `state_id`, `assignee_id`, `project_id`, `parent_id`, `cycle_id`, `priority`,
  `label_ids`). Blank optional values are treated as nil by Ecto's cast, so
  unset selects don't violate foreign keys.
  """
  @spec create_issue(Organization.t() | nil, map()) ::
          {:ok, Issue.t()} | {:error, Ecto.Changeset.t()}
  def create_issue(nil, _attrs), do: {:error, Issue.changeset(%Issue{}, %{})}

  def create_issue(%Organization{} = org, attrs) when is_map(attrs) do
    attrs = normalize_attrs(attrs)

    case %Issue{}
         |> Issue.changeset(build_issue_attrs(org, team_for(attrs), attrs))
         |> validate_issue_references()
         |> Repo.insert() do
      {:ok, issue} ->
        apply_label_ops(issue.id, attrs)
        {:ok, issue}

      error ->
        error
    end
  end

  @doc """
  Deletes an issue by internal id or ticket identifier (e.g. `ENG-1`).
  Comments/relations cascade via the DB.
  """
  @spec delete_issue(String.t()) :: {:ok, Issue.t()} | {:error, :not_found}
  def delete_issue(id) do
    case fetch_issue(id) do
      nil -> {:error, :not_found}
      issue -> Repo.delete(issue)
    end
  end

  @doc """
  Soft-archives an issue by stamping `archived_at` (by internal id or
  identifier). Archived issues drop out of `list_issues` but remain fetchable
  by id, mirroring Linear's `issueArchive`.
  """
  @spec archive_issue(String.t()) :: {:ok, Issue.t()} | {:error, :not_found}
  def archive_issue(id) do
    case fetch_issue(id) do
      nil -> {:error, :not_found}
      issue -> issue |> Issue.changeset(%{archived_at: DateTime.utc_now()}) |> Repo.update()
    end
  end

  ## Labels -----------------------------------------------------------------

  @doc "Lists an organization's labels, deterministically ordered."
  @spec list_labels(Organization.t() | nil) :: [Label.t()]
  def list_labels(nil), do: []

  def list_labels(%Organization{} = org) do
    Label
    |> where([l], l.organization_id == ^org.id)
    |> order_by([l], asc: l.inserted_at, asc: l.id)
    |> Repo.all()
  end

  @doc "Creates a label in the organization (Linear's `issueLabelCreate`)."
  @spec create_label(Organization.t() | nil, map()) ::
          {:ok, Label.t()} | {:error, Ecto.Changeset.t()}
  def create_label(nil, _attrs), do: {:error, Label.changeset(%Label{}, %{})}

  def create_label(%Organization{} = org, attrs) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.merge(%{"id" => "label_" <> Ecto.UUID.generate(), "organization_id" => org.id})

    %Label{} |> Label.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Attaches a label to an issue (Linear's `issueAddLabel`). Idempotent.
  Returns `{:error, :not_found}` if the issue or label does not exist.
  """
  @spec add_issue_label(String.t(), String.t()) :: {:ok, Issue.t()} | {:error, :not_found}
  def add_issue_label(issue_id, label_id) do
    with %Issue{} = issue <- fetch_issue(issue_id),
         %Label{} <- Repo.get(Label, label_id) do
      upsert_issue_label(issue.id, label_id)
      {:ok, issue}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Detaches a label from an issue (Linear's `issueRemoveLabel`). Idempotent —
  succeeds even if the label was not attached. `{:error, :not_found}` only if
  the issue itself is unknown.
  """
  @spec remove_issue_label(String.t(), String.t()) :: {:ok, Issue.t()} | {:error, :not_found}
  def remove_issue_label(issue_id, label_id) do
    case fetch_issue(issue_id) do
      nil ->
        {:error, :not_found}

      %Issue{} = issue ->
        Repo.delete_all(
          from il in IssueLabel, where: il.issue_id == ^issue.id and il.label_id == ^label_id
        )

        {:ok, issue}
    end
  end

  ## Relations --------------------------------------------------------------

  @doc """
  Creates a directed relation between two issues (Linear's `issueRelationCreate`).
  `issue_id`/`related_issue_id` accept internal ids or identifiers. `type` is one
  of #{inspect(IssueRelation.relation_types())}. Returns `{:error, :not_found}`
  if either issue is unknown.
  """
  @spec create_issue_relation(map()) ::
          {:ok, IssueRelation.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def create_issue_relation(attrs) do
    attrs = normalize_attrs(attrs)

    with %Issue{} = source <- fetch_issue(attrs["issue_id"]),
         %Issue{} = target <- fetch_issue(attrs["related_issue_id"]),
         {:ok, relation} <-
           %IssueRelation{}
           |> IssueRelation.changeset(%{
             "id" => attrs["id"] || "rel_" <> Ecto.UUID.generate(),
             "issue_id" => source.id,
             "related_issue_id" => target.id,
             "type" => attrs["type"]
           })
           |> Repo.insert() do
      {:ok, Repo.preload(relation, issue: :state, related_issue: :state)}
    else
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  @doc "Deletes an issue relation by id (Linear's `issueRelationDelete`)."
  @spec delete_issue_relation(String.t()) :: {:ok, IssueRelation.t()} | {:error, :not_found}
  def delete_issue_relation(id) do
    case Repo.get(IssueRelation, id) do
      nil -> {:error, :not_found}
      relation -> Repo.delete(relation)
    end
  end

  ## Attachments ------------------------------------------------------------

  @attachment_preloads [:issue, :creator]

  @doc "Lists an issue's attachments (by internal issue id), deterministically ordered."
  @spec list_attachments(String.t()) :: [Attachment.t()]
  def list_attachments(issue_id) do
    Attachment
    |> where([a], a.issue_id == ^issue_id)
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> preload(^@attachment_preloads)
    |> Repo.all()
  end

  @doc "Fetches an attachment by id (with issue/creator preloaded). Nil when absent."
  @spec get_attachment(String.t()) :: Attachment.t() | nil
  def get_attachment(id) do
    Attachment
    |> where([a], a.id == ^id)
    |> preload(^@attachment_preloads)
    |> Repo.one()
  end

  @doc """
  Lists an organization's attachments matching a url (Linear's `attachmentsForURL`).
  Scoped to the org via the owning issue.
  """
  @spec list_attachments_for_url(Organization.t() | nil, String.t()) :: [Attachment.t()]
  def list_attachments_for_url(nil, _url), do: []

  def list_attachments_for_url(%Organization{} = org, url) do
    Attachment
    |> join(:inner, [a], i in assoc(a, :issue))
    |> where([_a, i], i.organization_id == ^org.id)
    |> where([a], a.url == ^url)
    |> order_by([a], asc: a.inserted_at, asc: a.id)
    |> preload(^@attachment_preloads)
    |> Repo.all()
  end

  @doc """
  Creates an attachment, **upserting** on `(issue_id, url)` — a second call with
  the same pair updates the existing row's title/subtitle in place (matching
  Linear's `attachmentCreate`). `issue_id` accepts an internal id or identifier.
  """
  @spec create_attachment(map()) ::
          {:ok, Attachment.t()} | {:error, Ecto.Changeset.t() | :issue_not_found}
  def create_attachment(attrs) do
    attrs = normalize_attrs(attrs)

    case fetch_issue(attrs["issue_id"]) do
      nil ->
        {:error, :issue_not_found}

      %Issue{} = issue ->
        case existing_attachment(issue.id, attrs["url"]) do
          %Attachment{} = existing ->
            existing
            |> Attachment.changeset(Map.take(attrs, ["title", "subtitle", "source_type"]))
            |> Repo.update()
            |> preload_attachment()

          nil ->
            insert_attachment(issue.id, attrs)
        end
    end
  end

  @doc """
  Records a link on an issue (backs `attachmentLinkURL` / `attachmentLinkGitHubPR`
  / `attachmentLinkGitHubIssue`). **Errors** on a duplicate `(issue, url)` with
  `{:error, {:already_linked, identifier}}` rather than upserting — matching
  live Linear's "This URL has already been linked with <ID>." `issue_id` accepts
  an internal id or identifier.
  """
  @spec link_url(map()) ::
          {:ok, Attachment.t()}
          | {:error, Ecto.Changeset.t() | :issue_not_found | {:already_linked, String.t()}}
  def link_url(attrs) do
    attrs = normalize_attrs(attrs)

    case fetch_issue(attrs["issue_id"]) do
      nil ->
        {:error, :issue_not_found}

      %Issue{} = issue ->
        case existing_attachment(issue.id, attrs["url"]) do
          %Attachment{} -> {:error, {:already_linked, issue.identifier}}
          nil -> insert_attachment(issue.id, attrs)
        end
    end
  end

  @doc "Updates an attachment's title/subtitle (Linear's `attachmentUpdate`)."
  @spec update_attachment(String.t(), map()) ::
          {:ok, Attachment.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update_attachment(id, attrs) do
    case Repo.get(Attachment, id) do
      nil ->
        {:error, :not_found}

      attachment ->
        attachment
        |> Attachment.changeset(normalize_attrs(attrs))
        |> Repo.update()
        |> preload_attachment()
    end
  end

  @doc "Deletes an attachment by id (Linear's `attachmentDelete`)."
  @spec delete_attachment(String.t()) :: {:ok, Attachment.t()} | {:error, :not_found}
  def delete_attachment(id) do
    case Repo.get(Attachment, id) do
      nil -> {:error, :not_found}
      attachment -> Repo.delete(attachment)
    end
  end

  defp existing_attachment(issue_id, url) when is_binary(url),
    do: Repo.get_by(Attachment, issue_id: issue_id, url: url)

  defp existing_attachment(_issue_id, _url), do: nil

  defp insert_attachment(issue_id, attrs) do
    attrs
    |> Map.merge(%{"id" => "att_" <> Ecto.UUID.generate(), "issue_id" => issue_id})
    |> then(&Attachment.changeset(%Attachment{}, &1))
    |> Repo.insert()
    |> preload_attachment()
  end

  defp preload_attachment({:ok, attachment}),
    do: {:ok, Repo.preload(attachment, @attachment_preloads)}

  defp preload_attachment({:error, _} = error), do: error

  # Applies label_ids (full replace) and added/removed_label_ids (incremental)
  # from a normalized attrs map. Unknown label ids are skipped, not errors.
  defp apply_label_ops(issue_id, attrs) do
    if Map.has_key?(attrs, "label_ids") do
      Repo.delete_all(from il in IssueLabel, where: il.issue_id == ^issue_id)

      attrs
      |> Map.get("label_ids")
      |> existing_label_ids()
      |> Enum.each(&upsert_issue_label(issue_id, &1))
    end

    attrs
    |> Map.get("added_label_ids", [])
    |> existing_label_ids()
    |> Enum.each(&upsert_issue_label(issue_id, &1))

    Enum.each(List.wrap(Map.get(attrs, "removed_label_ids", [])), fn label_id ->
      Repo.delete_all(
        from il in IssueLabel, where: il.issue_id == ^issue_id and il.label_id == ^label_id
      )
    end)

    :ok
  end

  defp existing_label_ids(ids) do
    ids = ids |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))
    if ids == [], do: [], else: Repo.all(from l in Label, where: l.id in ^ids, select: l.id)
  end

  defp upsert_issue_label(issue_id, label_id) do
    unless Repo.get_by(IssueLabel, issue_id: issue_id, label_id: label_id) do
      Repo.insert!(%IssueLabel{
        id: "il_" <> Ecto.UUID.generate(),
        issue_id: issue_id,
        label_id: label_id
      })
    end
  end

  defp fetch_issue(id) do
    Repo.one(from i in Issue, where: i.id == ^id or i.identifier == ^id)
  end

  # Stringify top-level keys so atom-keyed (GraphQL) and string-keyed (web form)
  # callers share one code path; list/scalar values pass through untouched.
  defp normalize_attrs(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # Rejects *_id values that point at non-existent rows with a clean changeset
  # error rather than letting SQLite raise an unnamed FK constraint.
  defp validate_issue_references(changeset) do
    Enum.reduce(@issue_fk_checks, changeset, fn {field, schema}, cs ->
      case Ecto.Changeset.get_field(cs, field) do
        nil ->
          cs

        id ->
          if Repo.exists?(from r in schema, where: r.id == ^id),
            do: cs,
            else: Ecto.Changeset.add_error(cs, field, "does not reference an existing record")
      end
    end)
  end

  defp team_for(attrs) do
    case attrs["team_id"] do
      id when is_binary(id) and id != "" -> Repo.get(Team, id)
      _ -> nil
    end
  end

  # No (or unknown) team: stamp the id/org so the changeset reports the genuinely
  # missing fields (team_id, identifier, number) rather than a bare id error.
  defp build_issue_attrs(org, nil, attrs) do
    Map.merge(attrs, %{"id" => new_issue_id(), "organization_id" => org.id})
  end

  defp build_issue_attrs(org, %Team{} = team, attrs) do
    number = next_issue_number(team.id)
    identifier = "#{team.key}-#{number}"

    Map.merge(attrs, %{
      "id" => new_issue_id(),
      "organization_id" => org.id,
      "team_id" => team.id,
      "number" => number,
      "identifier" => identifier,
      "url" => issue_url(org, identifier),
      "branch_name" => issue_branch_name(identifier)
    })
  end

  defp next_issue_number(team_id) do
    max =
      Issue
      |> where([i], i.team_id == ^team_id)
      |> select([i], max(i.number))
      |> Repo.one()

    (max || 0) + 1
  end

  defp new_issue_id, do: "issue_" <> Ecto.UUID.generate()

  defp issue_url(%Organization{url_key: url_key}, identifier),
    do: "https://linear.app/#{url_key}/issue/#{identifier}"

  defp issue_branch_name(identifier), do: "sim/" <> String.downcase(identifier)

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
