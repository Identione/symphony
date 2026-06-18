defmodule LinearSimWeb.ResponseModeTest do
  @moduledoc "Canned-error response modes set by scenarios (rate_limited/invalid_token/permission_denied)."
  use LinearSimWeb.ConnCase, async: false

  # Reset back to a normal scenario so the persistent response mode does not leak
  # into other tests.
  setup do
    on_exit(fn -> LinearSim.Scenarios.load!("basic_workspace") end)
    :ok
  end

  defp viewer(conn) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer user_hakan")
    |> post("/graphql", %{"query" => "{ viewer { id } }"})
    |> json_response(200)
  end

  @tag scenario: :rate_limited
  test "rate_limited returns a RATELIMITED error body", %{conn: conn} do
    assert [error | _] = viewer(conn)["errors"]
    assert get_in(error, ["extensions", "type"]) == "RATELIMITED"
  end

  @tag scenario: :invalid_token
  test "invalid_token returns an AUTHENTICATION_ERROR body", %{conn: conn} do
    assert [error | _] = viewer(conn)["errors"]
    assert get_in(error, ["extensions", "type"]) == "AUTHENTICATION_ERROR"
  end

  @tag scenario: :permission_denied
  test "permission_denied returns a FORBIDDEN body", %{conn: conn} do
    assert [error | _] = viewer(conn)["errors"]
    assert get_in(error, ["extensions", "type"]) == "FORBIDDEN"
  end

  test "normal scenario resolves data without a forced error", %{conn: conn} do
    assert get_in(viewer(conn), ["data", "viewer", "id"]) == "user_hakan"
  end
end
