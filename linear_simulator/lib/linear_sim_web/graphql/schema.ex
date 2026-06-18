defmodule LinearSimWeb.GraphQL.Schema do
  @moduledoc """
  Root Absinthe schema for the Linear API simulator.

  Operation-driven: only the types, queries, and mutations actually used by the
  target client (symphony) are implemented. See `docs/linear-sim.md` §15 for the
  full operation inventory.
  """
  use Absinthe.Schema

  import_types(Absinthe.Type.Custom)
  import_types(LinearSimWeb.GraphQL.Types.CommonTypes)
  import_types(LinearSimWeb.GraphQL.Types.UserTypes)
  import_types(LinearSimWeb.GraphQL.Types.IssueTypes)
  import_types(LinearSimWeb.GraphQL.Types.ProjectTypes)
  import_types(LinearSimWeb.GraphQL.Types.CommentTypes)

  query do
    import_fields(:viewer_queries)
    import_fields(:issue_queries)
    import_fields(:project_queries)

    @desc "Simulator API version. Placeholder query used by skeleton smoke tests."
    field :api_version, non_null(:string) do
      resolve(fn _parent, _args, _resolution ->
        {:ok, "linear-sim/0.1.0"}
      end)
    end
  end

  mutation do
    import_fields(:issue_mutations)
    import_fields(:comment_mutations)
  end
end
