defmodule Mix.Tasks.LinearSim.DumpSchemaTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.LinearSim.DumpSchema

  setup do
    out_dir =
      Path.join(System.tmp_dir!(), "dump_schema_test_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(out_dir) end)
    %{out_dir: out_dir}
  end

  test "writes both the SDL and the introspection JSON", %{out_dir: out_dir} do
    assert {:ok, paths} = DumpSchema.dump(out_dir: out_dir)

    assert File.read!(paths.sdl) =~ "type RootQueryType"

    json = paths.json |> File.read!() |> Jason.decode!()
    assert %{"__schema" => %{"types" => types}} = json
    assert Enum.any?(types, &(&1["name"] == "Issue"))
  end
end
