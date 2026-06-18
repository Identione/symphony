defmodule LinearSim.Compat.PathsTest do
  use ExUnit.Case, async: true

  alias LinearSim.Compat.Paths

  describe "get_path/2" do
    test "walks nested maps" do
      assert Paths.get_path(%{"a" => %{"b" => 1}}, ["a", "b"]) == 1
    end

    test "indexes into lists with numeric segments" do
      value = %{"a" => %{"b" => [%{"c" => 1}, %{"c" => 2}]}}
      assert Paths.get_path(value, ["a", "b", "0", "c"]) == 1
      assert Paths.get_path(value, ["a", "b", "1", "c"]) == 2
    end

    test "returns nil for a missing key" do
      assert Paths.get_path(%{"a" => 1}, ["nope"]) == nil
      assert Paths.get_path(%{"a" => 1}, ["a", "deeper"]) == nil
    end

    test "empty segment list returns the value itself" do
      assert Paths.get_path(%{"a" => 1}, []) == %{"a" => 1}
    end
  end

  describe "get/2 with a dotted string" do
    test "splits on dots" do
      assert Paths.get(
               %{"data" => %{"issues" => %{"nodes" => [%{"id" => "x"}]}}},
               "data.issues.nodes.0.id"
             ) ==
               "x"
    end
  end

  describe "compare/2" do
    test "returns :ok when every expected path matches" do
      response = %{"data" => %{"issues" => %{"pageInfo" => %{"hasNextPage" => false}}}}
      assert Paths.compare(response, %{"data.issues.pageInfo.hasNextPage" => false}) == :ok
    end

    test "returns :ok for an empty expectation map" do
      assert Paths.compare(%{"data" => %{}}, %{}) == :ok
    end

    test "reports mismatches with path, expected and actual" do
      response = %{"data" => %{"issues" => %{"nodes" => [%{"id" => "ENG-1"}]}}}

      assert {:error, mismatches} =
               Paths.compare(response, %{"data.issues.nodes.0.id" => "ENG-2"})

      assert {"data.issues.nodes.0.id", "ENG-2", "ENG-1"} in mismatches
    end
  end
end
