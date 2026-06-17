defmodule LinearSimWeb.GraphQL.Resolvers.TeamResolver do
  @moduledoc "Resolvers for team fields (e.g. workflow state lookup)."

  alias LinearSim.GraphQL.Connection
  alias LinearSim.Linear

  @doc "Resolves `team.states(filter:)` into a connection."
  @spec states(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def states(team, args, _resolution) do
    name_eq = get_in(args, [:filter, :name, :eq])
    {:ok, Connection.from_nodes(Linear.list_team_states(team.id, name_eq), args)}
  end
end
