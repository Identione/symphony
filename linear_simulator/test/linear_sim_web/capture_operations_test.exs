defmodule LinearSimWeb.CaptureOperationsTest do
  use LinearSimWeb.ConnCase, async: false

  setup do
    dir = Path.join(System.tmp_dir!(), "linear_sim_capture_#{System.unique_integer([:positive])}")

    Application.put_env(:linear_sim, :operation_capture,
      enabled: true,
      directory: dir,
      include_variables: true,
      redact_variables: ["token", "apiKey"]
    )

    on_exit(fn ->
      Application.put_env(:linear_sim, :operation_capture, enabled: false)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "captures the operation document, variables (redacted), and metadata", %{conn: conn, dir: dir} do
    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer user_hakan")
    |> post("/graphql", %{
      "query" => "query Probe($token: String) { viewer { id } }",
      "variables" => %{"token" => "supersecret", "keep" => "visible"},
      "operationName" => "Probe"
    })

    graphql = Path.wildcard(Path.join(dir, "*-Probe.graphql"))
    assert [doc_path] = graphql
    assert File.read!(doc_path) =~ "query Probe"

    [vars_path] = Path.wildcard(Path.join(dir, "*-Probe.variables.json"))
    vars = vars_path |> File.read!() |> Jason.decode!()
    assert vars["token"] == "[REDACTED]"
    assert vars["keep"] == "visible"

    [meta_path] = Path.wildcard(Path.join(dir, "*-Probe.metadata.json"))
    meta = meta_path |> File.read!() |> Jason.decode!()
    assert meta["operationName"] == "Probe"
    assert meta["authToken"] == "Bearer user_hak..."
  end

  test "captures anonymous operations without an operationName", %{conn: conn, dir: dir} do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/graphql", %{"query" => "{ viewer { id } }"})

    assert [_] = Path.wildcard(Path.join(dir, "*-anonymous.graphql"))
  end
end
