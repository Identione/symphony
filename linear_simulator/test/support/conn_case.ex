defmodule LinearSimWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use LinearSimWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint LinearSimWeb.Endpoint

      use LinearSimWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import LinearSimWeb.ConnCase

      @doc """
      POSTs a GraphQL query (with variables) to `/graphql` as the default test
      user and returns the parsed JSON body. Defined here so every GraphQL test
      shares one client instead of redefining its own.
      """
      def gql(conn, query, variables \\ %{}) do
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer user_hakan")
        |> post("/graphql", %{"query" => query, "variables" => variables})
        |> json_response(200)
      end
    end
  end

  setup tags do
    LinearSim.DataCase.reset_state!(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
