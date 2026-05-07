defmodule SymphonyElixir.ClaudeSidecarSetupTest do
  use ExUnit.Case, async: true

  @moduletag :sidecar_setup

  test "Makefile exposes sidecar-deps target hooked into setup" do
    makefile = File.read!(Path.expand("../../Makefile", __DIR__))

    assert Regex.match?(~r/^sidecar-deps:/m, makefile),
           "expected a `sidecar-deps:` Make target"

    assert makefile =~ "uv sync --frozen",
           "sidecar-deps must run `uv sync --frozen` for reproducible installs"

    assert Regex.match?(~r/^setup:.*sidecar-deps/m, makefile),
           "`setup:` must depend on `sidecar-deps`"
  end
end
