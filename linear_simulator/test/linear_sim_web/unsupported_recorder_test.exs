defmodule LinearSimWeb.GraphQL.UnsupportedRecorderTest do
  @moduledoc """
  Operations whose fields/args/enums are not in the simulator schema are rejected
  by Absinthe's validation phase. The recorder appends those — and only those — to
  a single JSONL file, deduplicated by signature, so gaps are easy to find and fill
  (docs/linear-sim.md).
  """
  use LinearSimWeb.ConnCase, async: false

  alias LinearSimWeb.GraphQL.UnsupportedRecorder

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "linear_sim_unsupported_#{System.unique_integer([:positive])}.jsonl"
      )

    File.rm(path)
    previous = Application.get_env(:linear_sim, :unsupported_operations)

    Application.put_env(:linear_sim, :unsupported_operations,
      enabled: true,
      path: path,
      redact_variables: ["accessToken", "apiKey", "password", "token"]
    )

    on_exit(fn ->
      File.rm(path)

      if previous,
        do: Application.put_env(:linear_sim, :unsupported_operations, previous),
        else: Application.delete_env(:linear_sim, :unsupported_operations)
    end)

    {:ok, path: path}
  end

  defp lines(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      {:error, :enoent} ->
        []
    end
  end

  test "records an operation referencing a field the schema cannot handle", %{
    conn: conn,
    path: path
  } do
    body = gql(conn, "query Bogus { viewer { id nope } }")
    assert [_ | _] = body["errors"]

    assert [entry] = lines(path)
    assert entry["operationName"] == "Bogus"
    assert entry["query"] =~ "nope"
    assert Enum.any?(entry["errors"], &(&1 =~ ~r/Cannot query field "nope"/))
    assert is_binary(entry["capturedAt"])
  end

  test "does NOT record resolution/business errors (they carry a path)", %{
    conn: conn,
    path: path
  } do
    # Valid against the schema, but the resolver rejects it with a structured
    # changeset error — this is normal API behaviour, not a missing operation.
    mutation = """
    mutation { issueCreate(input: {teamId: "team_eng", title: ""}) { success } }
    """

    body = gql(conn, mutation)
    assert [error | _] = body["errors"]
    assert get_in(error, ["extensions", "code"]) == "VALIDATION_ERROR"

    assert lines(path) == []
  end

  test "deduplicates by signature: same gap once, a different gap adds a line", %{
    conn: conn,
    path: path
  } do
    gql(conn, "query Bogus { viewer { id nope } }")
    gql(conn, "query Bogus { viewer { id nope } }")
    assert length(lines(path)) == 1

    gql(conn, "query Other { viewer { id alsoMissing } }")
    assert length(lines(path)) == 2
  end

  test "count/0 reports the number of distinct recorded gaps", %{conn: conn} do
    assert UnsupportedRecorder.count() == 0

    gql(conn, "query A { viewer { id nope } }")
    gql(conn, "query B { viewer { id alsoMissing } }")
    # A duplicate of the first gap must not inflate the count.
    gql(conn, "query A { viewer { id nope } }")

    assert UnsupportedRecorder.count() == 2
  end

  test "list/0 returns decoded entries, most recent first", %{conn: conn} do
    assert UnsupportedRecorder.list() == []

    gql(conn, "query A { viewer { id nope } }")
    gql(conn, "query B { viewer { id alsoMissing } }")

    entries = UnsupportedRecorder.list()
    assert Enum.map(entries, & &1["operationName"]) == ["B", "A"]
    assert [%{"errors" => [_ | _], "query" => _} | _] = entries
  end

  test "writes nothing when disabled", %{conn: conn, path: path} do
    Application.put_env(:linear_sim, :unsupported_operations, enabled: false, path: path)

    body = gql(conn, "query Bogus { viewer { id nope } }")
    assert [_ | _] = body["errors"]
    assert lines(path) == []
  end
end
