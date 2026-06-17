defmodule LinearSimWeb.RateLimitedTest do
  use LinearSimWeb.ConnCase, async: false

  # Reset back to a normal scenario so the persistent response mode does not leak
  # into other tests.
  setup do
    on_exit(fn -> LinearSim.Scenarios.load!("basic_workspace") end)
    :ok
  end

  @tag scenario: :rate_limited
  test "rate_limited scenario returns a RATELIMITED error body on /graphql", %{conn: conn} do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer user_hakan")
      |> post("/graphql", %{"query" => "{ viewer { id } }"})
      |> json_response(200)

    assert [error | _] = body["errors"]
    assert get_in(error, ["extensions", "type"]) == "RATELIMITED"
  end

  test "normal scenario does not rate-limit", %{conn: conn} do
    body =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer user_hakan")
      |> post("/graphql", %{"query" => "{ viewer { id } }"})
      |> json_response(200)

    assert get_in(body, ["data", "viewer", "id"]) == "user_hakan"
  end
end
