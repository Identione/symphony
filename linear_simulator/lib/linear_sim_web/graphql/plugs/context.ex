defmodule LinearSimWeb.GraphQL.Plugs.Context do
  @moduledoc """
  Parses the `Authorization: Bearer <token>` header into the Absinthe context
  (docs/linear-sim.md §14). Missing header falls back to the default scenario
  user; an unrecognised token sets `auth_error: :invalid_token` so resolvers can
  return a Linear-like auth error.
  """
  @behaviour Plug

  import Plug.Conn

  alias LinearSim.Linear

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    context =
      conn
      |> get_req_header("authorization")
      |> parse_authorization()
      |> build_context()

    Absinthe.Plug.put_options(conn, context: context)
  end

  defp parse_authorization(["Bearer " <> token | _]), do: String.trim(token)
  defp parse_authorization([token | _]) when is_binary(token), do: String.trim(token)
  defp parse_authorization(_), do: nil

  defp build_context(nil) do
    %{
      current_user: Linear.default_user(),
      current_organization: Linear.default_organization()
    }
  end

  defp build_context(token) do
    case Linear.resolve_token(token) do
      {:ok, user, organization} ->
        %{
          current_user: user,
          current_organization: organization,
          simulator_token: token
        }

      :error ->
        %{
          current_user: nil,
          current_organization: nil,
          simulator_token: token,
          auth_error: :invalid_token
        }
    end
  end
end
