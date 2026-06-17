defmodule LinearSimWeb.SkeletonTest do
  @moduledoc """
  Milestone 1 smoke tests: the app boots, /health works, /graphql is mounted,
  and the Absinthe schema responds to a trivial query.
  """
  use LinearSimWeb.ConnCase, async: false

  test "GET /health returns ok", %{conn: conn} do
    conn = get(conn, "/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "POST /graphql answers a trivial query", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/graphql", %{"query" => "{ apiVersion }"})

    assert %{"data" => %{"apiVersion" => version}} = json_response(conn, 200)
    assert is_binary(version)
  end
end
