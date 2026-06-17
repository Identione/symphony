defmodule LinearSimWeb.GraphQL.Types.UserTypes do
  @moduledoc "GraphQL types and queries for users / the viewer."
  use Absinthe.Schema.Notation

  alias LinearSimWeb.GraphQL.Resolvers.ViewerResolver

  @desc "A Linear user."
  object :user do
    field :id, non_null(:id)
    field :name, :string
    field :email, :string
  end

  object :viewer_queries do
    @desc "The currently authenticated user, resolved from the bearer token."
    field :viewer, :user do
      resolve(&ViewerResolver.viewer/3)
    end
  end
end
