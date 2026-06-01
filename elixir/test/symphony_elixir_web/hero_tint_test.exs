defmodule SymphonyElixirWeb.HeroTintTest do
  use ExUnit.Case, async: true

  alias SymphonyElixirWeb.HeroTint

  describe "hue_for/1" do
    test "is deterministic for the same project name" do
      assert HeroTint.hue_for("symphony-implementation-2e32f5d86d8c") ==
               HeroTint.hue_for("symphony-implementation-2e32f5d86d8c")
    end

    test "returns a hue in [0, 360)" do
      for name <- sample_project_names() do
        hue = HeroTint.hue_for(name)
        assert is_integer(hue)
        assert hue >= 0
        assert hue < 360
      end
    end

    test "distinct names map to distinct hues" do
      hues = Enum.map(sample_project_names(), &HeroTint.hue_for/1)
      assert hues == Enum.uniq(hues)
    end
  end

  describe "inline_style/1" do
    test "returns nil for nil or empty project names" do
      assert HeroTint.inline_style(nil) == nil
      assert HeroTint.inline_style("") == nil
    end

    test "emits both background and border custom properties" do
      style = HeroTint.inline_style("symphony-implementation-2e32f5d86d8c")

      assert is_binary(style)
      assert style =~ "--hero-tint-bg:"
      assert style =~ "--hero-tint-border:"
    end

    test "uses the hue from hue_for/1" do
      name = "another-project-slug"
      hue = HeroTint.hue_for(name)
      style = HeroTint.inline_style(name)

      assert style =~ "hsl(#{hue}"
    end

    test "is deterministic across calls" do
      name = "stable-name"
      assert HeroTint.inline_style(name) == HeroTint.inline_style(name)
    end
  end

  defp sample_project_names do
    [
      "symphony-implementation-2e32f5d86d8c",
      "symphony-implementation-9aaa11223344",
      "alpha-project",
      "beta-project",
      "gamma-project",
      "platform-core",
      "ide",
      "observability-team",
      "ml-platform",
      "infra-foundations"
    ]
  end
end
