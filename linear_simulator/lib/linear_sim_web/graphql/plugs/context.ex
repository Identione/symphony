defmodule LinearSimWeb.GraphQL.Plugs.Context do
  @moduledoc """
  Parses the `Authorization: Bearer <token>` header into the Absinthe context
  (docs/linear-sim.md §14). Missing header falls back to the default scenario
  user; an unrecognised token sets `auth_error: :invalid_token` so resolvers can
  return a Linear-like auth error.
  """
  @behaviour Plug

  import Plug.Conn

  alias LinearSim.Compat.Context

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    context =
      conn
      |> get_req_header("authorization")
      |> List.first()
      |> Context.from_auth()

    Absinthe.Plug.put_options(conn, context: context)
  end
end
