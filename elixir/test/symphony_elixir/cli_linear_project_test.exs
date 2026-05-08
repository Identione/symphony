defmodule SymphonyElixir.CLI.LinearProjectTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.CLI.LinearProject

  describe "parse/1" do
    test "extracts the URL slug from a Linear project URL" do
      assert {:ok, %{slug: "symphony-2e32f5d86d8c", slug_id: "2e32f5d86d8c"}} =
               LinearProject.parse("https://linear.app/identione/project/symphony-2e32f5d86d8c")
    end

    test "ignores trailing path/query segments after the slug" do
      assert {:ok, %{slug: "abc-1234567890ab"}} =
               LinearProject.parse("https://linear.app/identione/project/abc-1234567890ab/active?foo=bar")
    end

    test "accepts the bare URL slug without an http prefix" do
      assert {:ok, %{slug: "symphony-2e32f5d86d8c", slug_id: "2e32f5d86d8c"}} =
               LinearProject.parse("symphony-2e32f5d86d8c")
    end

    test "accepts a hex-only slug id" do
      assert {:ok, %{slug: "2e32f5d86d8c", slug_id: "2e32f5d86d8c"}} =
               LinearProject.parse("2e32f5d86d8c")
    end

    test "returns slug_id nil when no trailing 12-hex is found" do
      assert {:ok, %{slug: "no-hex-suffix", slug_id: nil}} =
               LinearProject.parse("no-hex-suffix")
    end

    test "trims surrounding whitespace" do
      assert {:ok, %{slug: "symphony-2e32f5d86d8c"}} =
               LinearProject.parse("  symphony-2e32f5d86d8c  ")
    end

    test "rejects an empty value" do
      assert {:error, message} = LinearProject.parse("")
      assert message =~ "missing"
    end

    test "rejects a non-binary value" do
      assert {:error, message} = LinearProject.parse(nil)
      assert message =~ "missing"
    end

    test "rejects a URL that doesn't include /project/<slug>" do
      assert {:error, message} =
               LinearProject.parse("https://linear.app/identione/team/IDE")

      assert message =~ "could not parse"
    end

    test "rejects a value with disallowed characters" do
      assert {:error, message} = LinearProject.parse("not a slug!")
      assert message =~ "expected a Linear project URL"
    end
  end
end
