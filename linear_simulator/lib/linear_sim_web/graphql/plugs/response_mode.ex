defmodule LinearSimWeb.GraphQL.Plugs.ResponseMode do
  @moduledoc """
  Short-circuits `/graphql` with a canned Linear-style error body when the
  simulator is in a non-`:normal` response mode (docs/linear-sim.md §20).

  Modes are set by scenarios (`Scenarios.load!/1` → `LinearSim.Mode`):

    * `:rate_limited`    — `RATELIMITED` error (symphony's RateLimit breaker)
    * `:invalid_token`   — authentication error
    * `:permission_denied` — authorization error

  All are returned as HTTP 200 with an `errors` body, the common GraphQL shape;
  the distinguishing signal is `extensions.type`.
  """
  @behaviour Plug

  import Plug.Conn

  @bodies %{
    rate_limited: %{
      errors: [
        %{
          message: "Rate limit exceeded",
          extensions: %{
            type: "RATELIMITED",
            userPresentableMessage: "Rate limit exceeded. Please try again later."
          }
        }
      ]
    },
    invalid_token: %{
      errors: [
        %{
          message: "Authentication required",
          extensions: %{type: "AUTHENTICATION_ERROR"}
        }
      ]
    },
    permission_denied: %{
      errors: [
        %{
          message: "You don't have permission to access this resource",
          extensions: %{type: "FORBIDDEN"}
        }
      ]
    }
  }

  @encoded Map.new(@bodies, fn {mode, body} -> {mode, Jason.encode!(body)} end)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Map.get(@encoded, LinearSim.Mode.get()) do
      nil ->
        conn

      body ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)
        |> halt()
    end
  end
end
