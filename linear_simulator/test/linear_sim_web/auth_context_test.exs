defmodule LinearSimWeb.AuthContextTest do
  use LinearSimWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  require Logger

  defp post_graphql(conn, query, auth \\ nil) do
    conn = put_req_header(conn, "content-type", "application/json")
    conn = if auth, do: put_req_header(conn, "authorization", auth), else: conn
    post(conn, "/graphql", %{"query" => query})
  end

  describe "viewer query" do
    test "resolves the token-specific user from the bearer header", %{conn: conn} do
      conn = post_graphql(conn, "{ viewer { id name } }", "Bearer user_hakan")

      assert %{"data" => %{"viewer" => %{"id" => "user_hakan", "name" => name}}} =
               json_response(conn, 200)

      assert name == "Håkan Niska"
    end

    test "falls back to the default user when no auth header is present", %{conn: conn} do
      conn = post_graphql(conn, "{ viewer { id } }")
      assert %{"data" => %{"viewer" => %{"id" => "user_hakan"}}} = json_response(conn, 200)
    end

    test "returns an auth error for an unknown token", %{conn: conn} do
      conn = post_graphql(conn, "{ viewer { id } }", "Bearer totally_unknown")
      body = json_response(conn, 200)
      assert body["data"] == %{"viewer" => nil}
      assert [%{"message" => "Authentication required"} | _] = body["errors"]
    end
  end

  describe "request logging" do
    test "logs the request without leaking the full secret", %{conn: conn} do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          post_graphql(conn, "{ viewer { id } }", "Bearer supersecrettoken12345")
        end)

      assert log =~ "GraphQL request"
      refute log =~ "supersecrettoken12345"
    end
  end
end
