defmodule LinearSimWeb.GraphQL.Resolvers.TeamResolver do
  @moduledoc "Resolvers for team queries and team fields (e.g. workflow state lookup)."

  alias LinearSim.GraphQL.Connection
  alias LinearSim.Linear

  @doc "Resolves the `teams` query into a connection."
  @spec list(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def list(_parent, args, resolution) do
    {:ok, Connection.from_nodes(Linear.list_teams(org(resolution)), args)}
  end

  @doc "Resolves `team(id:)` by internal id or team key."
  @spec get(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def get(_parent, %{id: id}, resolution) do
    {:ok, Linear.get_team(org(resolution), id)}
  end

  @doc "Resolves `team.states(filter:)` into a connection."
  @spec states(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def states(team, args, _resolution) do
    name_eq = get_in(args, [:filter, :name, :eq])
    {:ok, Connection.from_nodes(Linear.list_team_states(team.id, name_eq), args)}
  end

  @doc "Resolves `WorkflowState.team` (nil when the association is not loaded)."
  @spec state_team(map(), map(), Absinthe.Resolution.t()) :: {:ok, struct() | nil}
  def state_team(%{team: %Ecto.Association.NotLoaded{}}, _args, _resolution), do: {:ok, nil}
  def state_team(%{team: team}, _args, _resolution), do: {:ok, team}

  @doc "Resolves `WorkflowState.position`, coercing the stored integer to Linear's `Float!`."
  @spec state_position(map(), map(), Absinthe.Resolution.t()) :: {:ok, float() | nil}
  def state_position(%{position: position}, _args, _resolution), do: {:ok, position && position / 1}

  @doc "Resolves the root `workflowStates(filter:)` query into a connection."
  @spec workflow_states(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def workflow_states(_parent, args, resolution) do
    filter = Map.get(args, :filter, %{})
    {:ok, Connection.from_nodes(Linear.list_workflow_states(org(resolution), filter), args)}
  end

  defp org(%{context: %{current_organization: org}}), do: org
  defp org(_), do: nil
end
