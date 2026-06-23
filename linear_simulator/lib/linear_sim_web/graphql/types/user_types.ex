defmodule LinearSimWeb.GraphQL.Types.UserTypes do
  @moduledoc "GraphQL types and queries for users / the viewer."
  use Absinthe.Schema.Notation

  alias LinearSimWeb.GraphQL.Resolvers.UserResolver
  alias LinearSimWeb.GraphQL.Resolvers.ViewerResolver

  @desc "A Linear user."
  object :user do
    field :id, non_null(:id)
    field :name, :string
    field :email, :string
    field :display_name, :string, resolve: &UserResolver.display_name/3

    field :assigned_issues, :issue_connection do
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&UserResolver.assigned_issues/3)
    end
  end

  object :user_edge do
    field :cursor, non_null(:string)
    field :node, :user
  end

  object :user_connection do
    field :nodes, list_of(:user)
    field :edges, list_of(:user_edge)
    field :page_info, non_null(:page_info)
  end

  object :viewer_queries do
    @desc "The currently authenticated user, resolved from the bearer token."
    field :viewer, :user do
      resolve(&ViewerResolver.viewer/3)
    end
  end

  object :user_queries do
    @desc "List the organization's users."
    field :users, :user_connection do
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&UserResolver.list/3)
    end
  end
end
