defmodule LinearSimWeb.GraphQL.Resolvers.ViewerResolver do
  @moduledoc "Resolves the `viewer` query from the Absinthe context (§14)."

  @doc "Returns the current user, or an auth error when the token is invalid."
  @spec viewer(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, struct()} | {:error, String.t()}
  def viewer(_parent, _args, %{context: %{current_user: user}}) when not is_nil(user) do
    {:ok, user}
  end

  def viewer(_parent, _args, _resolution) do
    {:error, "Authentication required"}
  end
end
