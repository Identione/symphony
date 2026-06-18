defmodule LinearSimWeb.GraphQL.Types.CommentTypes do
  @moduledoc "GraphQL types and mutations for comments and issue updates."
  use Absinthe.Schema.Notation

  alias LinearSimWeb.GraphQL.Resolvers.CommentResolver
  alias LinearSimWeb.GraphQL.Resolvers.IssueResolver

  @desc "A Linear issue comment."
  object :comment do
    field :id, non_null(:id)
    field :body, non_null(:string)
    field :resolved_at, :datetime
    field :created_at, :datetime, resolve: &CommentResolver.created_at/3
    field :updated_at, :datetime
  end

  object :comment_edge do
    field :cursor, non_null(:string)
    field :node, :comment
  end

  object :comment_connection do
    field :nodes, list_of(:comment)
    field :edges, list_of(:comment_edge)
    field :page_info, non_null(:page_info)
  end

  # --- Mutation inputs ---------------------------------------------------

  input_object :comment_create_input do
    field :issue_id, non_null(:string)
    field :body, non_null(:string)
  end

  input_object :comment_update_input do
    field :body, non_null(:string)
  end

  input_object :issue_update_input do
    field :state_id, :string
  end

  # --- Mutations ---------------------------------------------------------

  object :comment_mutations do
    @desc "Create a comment on an issue."
    field :comment_create, :comment_payload do
      arg(:input, non_null(:comment_create_input))
      resolve(&CommentResolver.create/3)
    end

    @desc "Update a comment's body."
    field :comment_update, :comment_payload do
      arg(:id, non_null(:string))
      arg(:input, non_null(:comment_update_input))
      resolve(&CommentResolver.update/3)
    end
  end

  object :issue_mutations do
    @desc "Update an issue (e.g. transition its workflow state)."
    field :issue_update, :issue_payload do
      arg(:id, non_null(:string))
      arg(:input, non_null(:issue_update_input))
      resolve(&IssueResolver.update/3)
    end
  end
end
