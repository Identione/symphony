defmodule LinearSim.Compat.SdlPrinterTest do
  use ExUnit.Case, async: true

  alias LinearSim.Compat.SdlPrinter

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "tiny_reference_schema.json"])

  defp sdl, do: @fixture |> File.read!() |> Jason.decode!() |> SdlPrinter.print()

  test "prints object types with their fields and named return types" do
    out = sdl()
    assert out =~ "type User {"
    assert out =~ "id: String"
  end

  test "prints field arguments and non-null/wrapper markers" do
    out = sdl()
    assert out =~ "node(id: ID!): User"
  end

  test "prints input objects and enums" do
    out = sdl()
    assert out =~ "input IssueCreateInput {"
    assert out =~ "title: String!"
    assert out =~ "enum IssuePriority {"
    assert out =~ "HIGH"
  end

  test "does not crash on scalar types that have no fields" do
    out = sdl()
    assert out =~ "scalar"
  end

  test "carries a header noting the SDL is best-effort" do
    assert sdl() =~ "best-effort"
  end
end
