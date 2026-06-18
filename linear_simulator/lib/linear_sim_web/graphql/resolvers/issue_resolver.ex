defmodule LinearSimWeb.GraphQL.Resolvers.IssueResolver do
  @moduledoc "Resolvers for issue queries, issue field connections, and issueUpdate."

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

  @doc "Resolves the `issueUpdate` mutation."
  @spec update(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, map()} | {:error, term()}
  def update(_parent, %{id: id, input: input}, _resolution) do
    attrs = Map.take(input, [:state_id])

    case Linear.update_issue(id, attrs) do
      {:ok, issue} -> {:ok, %{success: true, issue: issue}}
      {:error, :not_found} -> {:error, "Issue not found"}
      {:error, %Ecto.Changeset{} = cs} -> {:error, Errors.changeset_errors(cs)}
    end
  end

  defp org(%{context: %{current_organization: org}}), do: org
  defp org(_), do: nil
end
