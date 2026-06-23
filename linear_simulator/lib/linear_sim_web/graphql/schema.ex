defmodule LinearSimWeb.GraphQL.Schema do
  @moduledoc """
  Root Absinthe schema for the Linear API simulator.

  Operation-driven: only the types, queries, and mutations actually exercised
  against the simulator are implemented — Symphony's own adapter operations plus
  the agent-driven discovery/attachment surface (real Linear fields recorded as
  gaps in `priv/linear/operations/unsupported.jsonl`). See `docs/linear-sim.md`
  §15 for the full operation inventory.
  """
  use Absinthe.Schema

  import_types(Absinthe.Type.Custom)
  import_types(LinearSimWeb.GraphQL.Types.CommonTypes)
  import_types(LinearSimWeb.GraphQL.Types.UserTypes)
  import_types(LinearSimWeb.GraphQL.Types.IssueTypes)
  import_types(LinearSimWeb.GraphQL.Types.ProjectTypes)
  import_types(LinearSimWeb.GraphQL.Types.CommentTypes)
  import_types(LinearSimWeb.GraphQL.Types.AttachmentTypes)

  query do
    import_fields(:viewer_queries)
    import_fields(:user_queries)
    import_fields(:issue_queries)
    import_fields(:team_queries)
    import_fields(:project_queries)
    import_fields(:attachment_queries)

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
    import_fields(:attachment_mutations)
  end

  @doc """
  Appends `NotifyChanged` to every mutation field so a successful GraphQL
  mutation broadcasts `:sim_changed` and open dashboard pages refresh live.
  """
  @impl Absinthe.Schema
  def middleware(middleware, _field, %{identifier: :mutation}),
    do: middleware ++ [LinearSimWeb.GraphQL.NotifyChanged]

  def middleware(middleware, _field, _object), do: middleware
end
