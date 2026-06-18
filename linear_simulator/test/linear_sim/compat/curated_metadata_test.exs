defmodule LinearSim.Compat.CuratedMetadataTest do
  use ExUnit.Case, async: true

  @curated Path.wildcard(
             Path.join([
               File.cwd!(),
               "priv",
               "linear",
               "operations",
               "curated",
               "*",
               "metadata.json"
             ])
           )

  @levels ~w(shape behavior error webhook)

  test "there are 12 curated metadata files" do
    assert length(@curated) == 12
  end

  for path <- @curated do
    @path path

    test "#{Path.basename(Path.dirname(path))} carries a well-formed compatibility block" do
      meta = @path |> File.read!() |> Jason.decode!()
      compat = meta["compatibility"]

      assert is_map(compat), "missing compatibility block"
      assert compat["level"] in @levels, "unexpected level: #{inspect(compat["level"])}"
      assert is_list(compat["requiresBehavior"])
      assert is_list(compat["knownDifferences"])
    end
  end
end
