defmodule LinearSimWeb.OperationReplayTest do
  @moduledoc """
  Replays every curated symphony operation against deterministic scenarios
  (docs/linear-sim.md §7). Each operation directory carries its own GraphQL
  document, variables, scenario, auth, and expected response paths.
  """
  use LinearSimWeb.ConnCase, async: false

  @curated Path.wildcard(Path.join([File.cwd!(), "priv", "linear", "operations", "curated", "*"]))

  test "the curated corpus is non-empty" do
    # 5 client queries + 3 mutations + 4 preflight queries.
    assert length(@curated) == 12
  end

  for dir <- @curated do
    @dir dir

    test "replays #{Path.basename(dir)}", %{conn: conn} do
      operation = File.read!(Path.join(@dir, "operation.graphql"))
      variables = read_json(Path.join(@dir, "variables.json"))
      metadata = read_json(Path.join(@dir, "metadata.json"))

      :ok = LinearSim.Scenarios.load!(metadata["scenario"])

      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", metadata["auth"])
        |> post("/graphql", %{
          "query" => operation,
          "variables" => variables,
          "operationName" => metadata["operationName"]
        })
        |> json_response(200)

      unless get_in(metadata, ["expected", "allowErrors"]) do
        assert response["errors"] in [nil, []],
               "#{metadata["name"]} returned errors: #{inspect(response["errors"])}"
      end

      assert is_map(response["data"])

      case LinearSim.Compat.Paths.compare(
             response,
             get_in(metadata, ["expected", "paths"]) || %{}
           ) do
        :ok ->
          :ok

        {:error, mismatches} ->
          flunk(
            "#{metadata["name"]} path mismatches: " <>
              Enum.map_join(mismatches, "; ", fn {path, expected, actual} ->
                "expected #{path} == #{inspect(expected)}, got #{inspect(actual)}"
              end)
          )
      end
    end
  end

  defp read_json(path), do: path |> File.read!() |> Jason.decode!()
end
