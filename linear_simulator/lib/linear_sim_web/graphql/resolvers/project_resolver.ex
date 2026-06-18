defmodule LinearSimWeb.GraphQL.Resolvers.ProjectResolver do
  @moduledoc "Resolvers for the projects query and project.teams."

  alias LinearSim.GraphQL.Connection
  alias LinearSim.Linear

  @doc "Resolves the `projects` query into a connection."
  @spec list(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def list(_parent, args, resolution) do
    org = org(resolution)
    filter = Map.get(args, :filter, %{})
    {:ok, Connection.from_nodes(Linear.list_projects(org, filter), args)}
  end

  @doc "Resolves `project(id:)` by internal id or slug."
  @spec get(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def get(_parent, %{id: id}, resolution),
    do: {:ok, Linear.get_project_by_id_or_slug(org(resolution), id)}

  @doc "Resolves `project.teams` into a connection."
  @spec teams(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def teams(project, args, _resolution),
    do: {:ok, Connection.from_nodes(Linear.list_project_teams(project), args)}

  @doc "Resolves `project.issues` into a connection."
  @spec issues(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def issues(project, args, _resolution),
    do: {:ok, Connection.from_nodes(Linear.list_project_issues(project), args)}

  defp org(%{context: %{current_organization: org}}), do: org
  defp org(_), do: nil
end
