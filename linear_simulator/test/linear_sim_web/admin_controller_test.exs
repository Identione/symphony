defmodule LinearSimWeb.AdminControllerTest do
  use LinearSimWeb.ConnCase, async: false

  test "POST /admin/reset loads the default scenario", %{conn: conn} do
    conn = post(conn, "/admin/reset")
    assert json_response(conn, 200) == %{"ok" => true, "scenario" => "basic_workspace"}
  end

  test "POST /admin/scenario/:name loads a known scenario", %{conn: conn} do
    conn = post(conn, "/admin/scenario/empty_workspace")
    assert json_response(conn, 200) == %{"ok" => true, "scenario" => "empty_workspace"}
  end

  test "POST /admin/scenario/:name 404s for an unknown scenario", %{conn: conn} do
    conn = post(conn, "/admin/scenario/does_not_exist")
    body = json_response(conn, 404)
    assert body["ok"] == false
    assert is_list(body["known"])
  end

  test "GET /admin/state reports counts for the current scenario", %{conn: conn} do
    post(build_conn(), "/admin/scenario/basic_workspace")
    conn = get(conn, "/admin/state")
    body = json_response(conn, 200)
    assert body["ok"] == true
    assert body["counts"]["issues"] == 1
    assert body["counts"]["organizations"] == 1
  end
end
