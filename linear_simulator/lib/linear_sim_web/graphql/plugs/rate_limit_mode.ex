defmodule LinearSimWeb.GraphQL.Plugs.RateLimitMode do
  @moduledoc """
  Short-circuits `/graphql` with a Linear-style `RATELIMITED` error body when the
  simulator is in `:rate_limited` mode (docs/linear-sim.md §20). Returns HTTP 200
  with a structured error, the more common Linear behaviour; symphony's
  `RateLimit` module also detects this shape (not just HTTP 429).
  """
  @behaviour Plug

  import Plug.Conn

  @body Jason.encode!(%{
          errors: [
            %{
              message: "Rate limit exceeded",
              extensions: %{
                type: "RATELIMITED",
                userPresentableMessage: "Rate limit exceeded. Please try again later."
              }
            }
          ]
        })

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case LinearSim.Mode.get() do
      :rate_limited ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, @body)
        |> halt()

      _ ->
        conn
    end
  end
end
