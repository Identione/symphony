defmodule LinearSimWeb.GraphQL.Types.IssueTypes do
  @moduledoc "GraphQL types and queries for issues, teams, states, labels, relations."
  use Absinthe.Schema.Notation

  alias LinearSimWeb.GraphQL.Resolvers.IssueResolver
  alias LinearSimWeb.GraphQL.Resolvers.TeamResolver

  @desc "A team workflow state."
  object :workflow_state do
    field :id, non_null(:id)
    field :name, non_null(:string)
    field :type, :string
  end

  @desc "An issue label."
  object :label do
    field :id, non_null(:id)
    field :name, non_null(:string)
    field :color, :string
  end

  @desc "A directed relation; `issue` is the source (e.g. the blocker)."
  object :issue_relation do
    field :type, non_null(:string)
    field :issue, :issue
  end

  @desc "A Linear team."
  object :team do
    field :id, non_null(:id)
    field :key, :string
    field :name, :string

    field :states, :workflow_state_connection do
      arg(:filter, :workflow_state_filter)
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&TeamResolver.states/3)
    end
  end

  @desc "A Linear issue."
  object :issue do
    field :id, non_null(:id)
    field :identifier, non_null(:string)
    field :title, :string
    field :description, :string
    field :priority, :integer
    field :branch_name, :string
    field :url, :string
    field :state, :workflow_state
    field :assignee, :user
    field :team, :team

    field :created_at, :datetime, resolve: &IssueResolver.created_at/3
    field :updated_at, :datetime

    field :labels, :label_connection do
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&IssueResolver.labels/3)
    end

    field :children, :issue_connection do
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&IssueResolver.children/3)
    end

    field :parent, :issue, resolve: &IssueResolver.parent/3

    field :inverse_relations, :issue_relation_connection do
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&IssueResolver.inverse_relations/3)
    end

    field :comments, :comment_connection do
      arg(:first, :integer)
      arg(:after, :string)
      arg(:order_by, :pagination_order_by)
      resolve(&IssueResolver.comments/3)
    end
  end

  # --- Connections -------------------------------------------------------

  object :issue_edge do
    field :cursor, non_null(:string)
    field :node, :issue
  end

  object :issue_connection do
    field :nodes, list_of(:issue)
    field :edges, list_of(:issue_edge)
    field :page_info, non_null(:page_info)
  end

  object :label_edge do
    field :cursor, non_null(:string)
    field :node, :label
  end

  object :label_connection do
    field :nodes, list_of(:label)
    field :edges, list_of(:label_edge)
    field :page_info, non_null(:page_info)
  end

  object :workflow_state_edge do
    field :cursor, non_null(:string)
    field :node, :workflow_state
  end

  object :workflow_state_connection do
    field :nodes, list_of(:workflow_state)
    field :edges, list_of(:workflow_state_edge)
    field :page_info, non_null(:page_info)
  end

  object :issue_relation_edge do
    field :cursor, non_null(:string)
    field :node, :issue_relation
  end

  object :issue_relation_connection do
    field :nodes, list_of(:issue_relation)
    field :edges, list_of(:issue_relation_edge)
    field :page_info, non_null(:page_info)
  end

  # --- Filters -----------------------------------------------------------

  input_object :project_filter do
    field :slug_id, :string_comparator
  end

  input_object :workflow_state_filter do
    field :name, :string_comparator
  end

  input_object :issue_filter do
    field :id, :id_comparator
    field :project, :project_filter
    field :state, :workflow_state_filter
  end

  # --- Queries -----------------------------------------------------------

  object :issue_queries do
    @desc "List issues, filtered Linear-style by project/state/id."
    field :issues, :issue_connection do
      arg(:filter, :issue_filter)
      arg(:first, :integer)
      arg(:after, :string)
      arg(:last, :integer)
      arg(:before, :string)
      resolve(&IssueResolver.list/3)
    end

    @desc "Fetch a single issue by internal id or ticket identifier."
    field :issue, :issue do
      arg(:id, non_null(:string))
      resolve(&IssueResolver.get/3)
    end
  end
end
