defmodule LinearSimWeb.GraphQL.Resolvers.UserResolver do
  @moduledoc "Resolvers for the `users` query and the `User.displayName` field."

  alias LinearSim.GraphQL.Connection
  alias LinearSim.Linear

  @doc "Resolves the `users` query into a connection."
  @spec list(map(), map(), Absinthe.Resolution.t()) :: {:ok, map()}
  def list(_parent, args, resolution) do
    {:ok, Connection.from_nodes(Linear.list_users(org(resolution)), args)}
  end

  @doc "Resolves `User.displayName`, mirroring Linear's display name from the user's name."
  @spec display_name(map(), map(), Absinthe.Resolution.t()) :: {:ok, String.t() | nil}
  def display_name(%{name: name}, _args, _resolution), do: {:ok, name}

  defp org(%{context: %{current_organization: org}}), do: org
  defp org(_), do: nil
end
