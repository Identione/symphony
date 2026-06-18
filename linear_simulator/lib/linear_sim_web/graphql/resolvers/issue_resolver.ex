defmodule LinearSimWeb.GraphQL.Resolvers.IssueResolver do
  @moduledoc """
  Resolvers for issue queries, issue field connections, and the issue
  mutations (issueCreate, issueUpdate, issueArchive, issueDelete).
  """

  alias LinearSim.GraphQL.Connection
  alias LinearSim.Linear
  alias LinearSimWeb.GraphQL.Errors

  @doc "Resolves the `issues` query into a connection."
  @spec list(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def list(_parent, args, resolution) do
    org = org(resolution)
    filter = Map.get(args, :filter, %{})
    {:ok, Connection.from_nodes(Linear.list_issues(org, filter), args)}
  end

  @doc "Resolves `issue(id:)` by internal id or identifier."
  @spec get(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def get(_parent, %{id: id}, resolution) do
    {:ok, Linear.get_issue_by_id_or_identifier(org(resolution), id)}
  end

  @doc "Maps the issue's insertion timestamp to Linear's `createdAt`."
  @spec created_at(map(), map(), Absinthe.Resolution.t()) :: {:ok, DateTime.t() | nil}
  def created_at(%{inserted_at: ts}, _args, _resolution), do: {:ok, ts}

  @doc "Resolves an issue's labels connection."
  @spec labels(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def labels(issue, args, _resolution),
    do: {:ok, Connection.from_nodes(issue.labels, args)}

  @doc "Resolves an issue's children connection."
  @spec children(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def children(issue, args, _resolution),
    do: {:ok, Connection.from_nodes(issue.children, args)}

  @doc "Resolves an issue's parent (nil for top-level issues)."
  @spec parent(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def parent(%{parent: %Ecto.Association.NotLoaded{}}, _args, _resolution), do: {:ok, nil}
  def parent(%{parent: parent}, _args, _resolution), do: {:ok, parent}

  @doc "Resolves an issue's project (nil for issues with no project)."
  @spec project(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def project(%{project: %Ecto.Association.NotLoaded{}}, _args, _resolution), do: {:ok, nil}
  def project(%{project: project}, _args, _resolution), do: {:ok, project}

  @doc "Resolves an issue's outgoing relations (where it is the source)."
  @spec relations(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def relations(issue, args, _resolution),
    do: {:ok, Connection.from_nodes(issue.relations, args)}

  @doc "Resolves an issue's inverse relations (blocker check)."
  @spec inverse_relations(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def inverse_relations(issue, args, _resolution),
    do: {:ok, Connection.from_nodes(issue.inverse_relations, args)}

  @doc "Resolves an issue's comments connection."
  @spec comments(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def comments(issue, args, _resolution) do
    order = Map.get(args, :order_by, :created_at)
    {:ok, Connection.from_nodes(Linear.list_comments(issue.id, order), args)}
  end

  @doc "Resolves the `issueCreate` mutation."
  @spec create(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, term()}
  def create(_parent, %{input: input}, resolution) do
    org = org(resolution)

    case Linear.create_issue(org, input) do
      {:ok, issue} -> {:ok, %{success: true, issue: reload(org, issue)}}
      {:error, %Ecto.Changeset{} = cs} -> {:error, Errors.changeset_errors(cs)}
    end
  end

  @doc "Resolves the `issueUpdate` mutation (state and/or general fields)."
  @spec update(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, term()}
  def update(_parent, %{id: id, input: input}, resolution) do
    org = org(resolution)

    attrs =
      Map.take(input, [
        :state_id,
        :title,
        :description,
        :assignee_id,
        :project_id,
        :parent_id,
        :cycle_id,
        :priority,
        :label_ids,
        :added_label_ids,
        :removed_label_ids
      ])

    case Linear.update_issue(id, attrs) do
      {:ok, issue} -> {:ok, %{success: true, issue: reload(org, issue)}}
      {:error, :not_found} -> {:error, "Issue not found"}
      {:error, %Ecto.Changeset{} = cs} -> {:error, Errors.changeset_errors(cs)}
    end
  end

  @doc "Resolves the `issueArchive` mutation (soft archive)."
  @spec archive(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, term()}
  def archive(_parent, %{id: id}, resolution) do
    org = org(resolution)

    case Linear.archive_issue(id) do
      {:ok, issue} -> {:ok, %{success: true, entity: reload(org, issue)}}
      {:error, :not_found} -> {:error, "Issue not found"}
    end
  end

  @doc "Resolves the `issueDelete` mutation (hard delete)."
  @spec delete(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, term()}
  def delete(_parent, %{id: id}, _resolution) do
    case Linear.delete_issue(id) do
      {:ok, issue} -> {:ok, %{success: true, entity: issue}}
      {:error, :not_found} -> {:error, "Issue not found"}
    end
  end

  @doc "Resolves the `issueAddLabel` mutation."
  @spec add_label(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def add_label(_parent, %{id: id, label_id: label_id}, resolution) do
    label_op(Linear.add_issue_label(id, label_id), org(resolution))
  end

  @doc "Resolves the `issueRemoveLabel` mutation."
  @spec remove_label(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def remove_label(_parent, %{id: id, label_id: label_id}, resolution) do
    label_op(Linear.remove_issue_label(id, label_id), org(resolution))
  end

  defp label_op({:ok, issue}, org), do: {:ok, %{success: true, issue: reload(org, issue)}}
  defp label_op({:error, :not_found}, _org), do: {:error, "Issue or label not found"}

  @doc "Resolves the `issueRelationCreate` mutation."
  @spec create_relation(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def create_relation(_parent, %{input: input}, _resolution) do
    case Linear.create_issue_relation(input) do
      {:ok, relation} -> {:ok, %{success: true, issue_relation: relation}}
      {:error, :not_found} -> {:error, "Related issue not found"}
      {:error, %Ecto.Changeset{} = cs} -> {:error, Errors.changeset_errors(cs)}
    end
  end

  @doc "Resolves the `issueRelationDelete` mutation."
  @spec delete_relation(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def delete_relation(_parent, %{id: id}, _resolution) do
    case Linear.delete_issue_relation(id) do
      {:ok, relation} -> {:ok, %{success: true, entity_id: relation.id}}
      {:error, :not_found} -> {:error, "Relation not found"}
    end
  end

  # Reload with associations preloaded so nested GraphQL fields resolve.
  defp reload(org, issue), do: Linear.get_issue_by_id_or_identifier(org, issue.id) || issue

  defp org(%{context: %{current_organization: org}}), do: org
  defp org(_), do: nil
end
