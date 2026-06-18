defmodule LinearSimWeb.GraphQL.Types.CommentTypes do
  @moduledoc "GraphQL types and mutations for comments and issue updates."
  use Absinthe.Schema.Notation

  alias LinearSimWeb.GraphQL.Resolvers.CommentResolver
  alias LinearSimWeb.GraphQL.Resolvers.IssueResolver
  alias LinearSimWeb.GraphQL.Resolvers.LabelResolver

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
    field :title, :string
    field :description, :string
    field :assignee_id, :string
    field :project_id, :string
    field :parent_id, :string
    field :cycle_id, :string
    field :priority, :integer
    field :label_ids, list_of(non_null(:string))
    field :added_label_ids, list_of(non_null(:string))
    field :removed_label_ids, list_of(non_null(:string))
  end

  @desc "Fields for creating an issue. `teamId` drives the auto-assigned identifier."
  input_object :issue_create_input do
    field :team_id, non_null(:string)
    field :title, non_null(:string)
    field :description, :string
    field :state_id, :string
    field :assignee_id, :string
    field :project_id, :string
    field :parent_id, :string
    field :cycle_id, :string
    field :priority, :integer
    field :label_ids, list_of(non_null(:string))
  end

  @desc "Fields for creating a workspace label (Linear's IssueLabelCreateInput subset)."
  input_object :issue_label_create_input do
    field :name, non_null(:string)
    field :color, :string
  end

  @desc "Directed relationship between two issues (Linear's IssueRelationType)."
  enum :issue_relation_type do
    value(:blocks, as: "blocks", name: "blocks")
    value(:duplicate, as: "duplicate", name: "duplicate")
    value(:related, as: "related", name: "related")
    value(:similar, as: "similar", name: "similar")
  end

  @desc "Fields for creating an issue relation (Linear's IssueRelationCreateInput)."
  input_object :issue_relation_create_input do
    field :type, non_null(:issue_relation_type)
    field :issue_id, non_null(:string)
    field :related_issue_id, non_null(:string)
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
    @desc "Create an issue. Auto-assigns the identifier/number/url/branchName."
    field :issue_create, :issue_payload do
      arg(:input, non_null(:issue_create_input))
      resolve(&IssueResolver.create/3)
    end

    @desc "Update an issue (state transition and/or title/description/assignee/priority/project)."
    field :issue_update, :issue_payload do
      arg(:id, non_null(:string))
      arg(:input, non_null(:issue_update_input))
      resolve(&IssueResolver.update/3)
    end

    @desc "Soft-archive an issue (sets archivedAt; drops it from the issues query)."
    field :issue_archive, :issue_archive_payload do
      arg(:id, non_null(:string))
      resolve(&IssueResolver.archive/3)
    end

    @desc "Permanently delete an issue. Comments/relations cascade."
    field :issue_delete, :issue_archive_payload do
      arg(:id, non_null(:string))
      resolve(&IssueResolver.delete/3)
    end

    @desc "Attach a label to an issue."
    field :issue_add_label, :issue_payload do
      arg(:id, non_null(:string))
      arg(:label_id, non_null(:string))
      resolve(&IssueResolver.add_label/3)
    end

    @desc "Detach a label from an issue."
    field :issue_remove_label, :issue_payload do
      arg(:id, non_null(:string))
      arg(:label_id, non_null(:string))
      resolve(&IssueResolver.remove_label/3)
    end

    @desc "Create a workspace label."
    field :issue_label_create, :issue_label_payload do
      arg(:input, non_null(:issue_label_create_input))
      resolve(&LabelResolver.create/3)
    end

    @desc "Create a directed relation between two issues."
    field :issue_relation_create, :issue_relation_payload do
      arg(:input, non_null(:issue_relation_create_input))
      resolve(&IssueResolver.create_relation/3)
    end

    @desc "Delete an issue relation by id."
    field :issue_relation_delete, :delete_payload do
      arg(:id, non_null(:string))
      resolve(&IssueResolver.delete_relation/3)
    end
  end
end
