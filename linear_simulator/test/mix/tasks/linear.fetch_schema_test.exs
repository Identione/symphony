defmodule Mix.Tasks.Linear.FetchSchemaTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Linear.FetchSchema

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "tiny_reference_schema.json"])

  setup do
    out_dir =
      Path.join(System.tmp_dir!(), "fetch_schema_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(out_dir) end)
    %{out_dir: out_dir, canned: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "returns {:error, :no_token} and writes nothing when the token is missing", %{
    out_dir: out_dir
  } do
    assert FetchSchema.fetch_and_write(token: nil, out_dir: out_dir) == {:error, :no_token}
    refute File.dir?(out_dir)
  end

  test "writes the three reference artifacts from a stubbed introspection response", ctx do
    Req.Test.stub(FetchSchema, fn conn -> Req.Test.json(conn, %{"data" => ctx.canned}) end)

    assert {:ok, paths} =
             FetchSchema.fetch_and_write(
               token: "lin_api_fake",
               out_dir: ctx.out_dir,
               now: "2026-06-18T00:00:00Z",
               req_options: [plug: {Req.Test, FetchSchema}]
             )

    assert File.exists?(paths.json)
    assert File.exists?(paths.sdl)
    assert File.exists?(paths.metadata)

    json = paths.json |> File.read!() |> Jason.decode!()
    assert Map.has_key?(json, "__schema")

    assert paths.sdl |> File.read!() =~ "best-effort"

    metadata = paths.metadata |> File.read!() |> Jason.decode!()
    assert metadata["source"] == "linear"
    assert metadata["endpoint"] =~ "api.linear.app"
    assert {:ok, _dt, _} = DateTime.from_iso8601(metadata["fetchedAt"])
  end

  test "returns an error when the response carries no __schema", ctx do
    Req.Test.stub(FetchSchema, fn conn ->
      Req.Test.json(conn, %{"errors" => [%{"message" => "nope"}]})
    end)

    assert {:error, _} =
             FetchSchema.fetch_and_write(
               token: "lin_api_fake",
               out_dir: ctx.out_dir,
               req_options: [plug: {Req.Test, FetchSchema}]
             )
  end
end
