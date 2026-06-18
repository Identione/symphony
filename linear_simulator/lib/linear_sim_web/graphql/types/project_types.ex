defmodule LinearSimWeb.GraphQL.Types.ProjectTypes do
  @moduledoc """
  GraphQL types and queries for projects. Exercised by symphony's preflight
  (`projects(filter: {slugId: {eq}})` and the project→teams→states walk).
  """
  use Absinthe.Schema.Notation

  alias LinearSimWeb.GraphQL.Resolvers.ProjectResolver

  @desc "A Linear project."
  object :project do
    field :id, non_null(:id)
    field :name, :string
    field :slug_id, :string

    field :teams, :team_connection do
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&ProjectResolver.teams/3)
    end

    field :issues, :issue_connection do
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&ProjectResolver.issues/3)
    end
  end

  object :team_edge do
    field :cursor, non_null(:string)
    field :node, :team
  end

  object :team_connection do
    field :nodes, list_of(:team)
    field :edges, list_of(:team_edge)
    field :page_info, non_null(:page_info)
  end

  object :project_edge do
    field :cursor, non_null(:string)
    field :node, :project
  end

  object :project_connection do
    field :nodes, list_of(:project)
    field :edges, list_of(:project_edge)
    field :page_info, non_null(:page_info)
  end

  object :project_queries do
    @desc "List projects, filtered Linear-style by slug."
    field :projects, :project_connection do
      arg(:filter, :project_filter)
      arg(:first, :integer)
      arg(:after, :string)
      resolve(&ProjectResolver.list/3)
    end

    @desc "Fetch a single project by internal id or slug."
    field :project, :project do
      arg(:id, non_null(:string))
      resolve(&ProjectResolver.get/3)
    end
  end
end
