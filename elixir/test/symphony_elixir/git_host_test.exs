defmodule SymphonyElixir.GitHostTest do
  @moduledoc """
  Unit coverage for the `SymphonyElixir.GitHost` behaviour seam, its default
  `Gh` adapter's gate predicate, and the in-memory test adapter (IDE-233).
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHost
  alias SymphonyElixir.GitHost.Gh
  alias SymphonyElixir.GitHost.Memory

  setup do
    on_exit(fn ->
      Application.delete_env(:symphony_elixir, :git_host_adapter)
      Application.delete_env(:symphony_elixir, :memory_git_host_gate_active)
      Application.delete_env(:symphony_elixir, :memory_git_host_pr_merged)
      Application.delete_env(:symphony_elixir, :memory_git_host_default)
    end)

    :ok
  end

  test "defaults to the gh adapter" do
    assert GitHost.adapter() == Gh
  end

  test "gh adapter gate is inactive when no repo.url is configured" do
    # The default test workflow leaves repo.url nil, so the gate cannot key off
    # a GitHub remote and degrades to inactive (no holding).
    refute Gh.gate_active?()
  end

  test "gh adapter reports a missing PR url without shelling out" do
    assert Gh.pr_merged?(nil, nil) == {:error, :missing_pr_url}
    assert Gh.pr_merged?(nil, "") == {:error, :missing_pr_url}
  end

  describe "memory adapter" do
    setup do
      Application.put_env(:symphony_elixir, :git_host_adapter, Memory)
      :ok
    end

    test "gate is active by default and honors the override" do
      assert GitHost.gate_active?()

      Application.put_env(:symphony_elixir, :memory_git_host_gate_active, false)
      refute GitHost.gate_active?()
    end

    test "returns canned per-url merge responses and falls back to the default" do
      url = "https://github.com/Identione/symphony/pull/9"
      Application.put_env(:symphony_elixir, :memory_git_host_pr_merged, %{url => {:ok, true}})

      assert GitHost.pr_merged?(nil, url) == {:ok, true}
      # Unknown urls use the configured default (itself defaulting to {:ok, false}).
      assert GitHost.pr_merged?(nil, "https://github.com/x/y/pull/1") == {:ok, false}

      Application.put_env(:symphony_elixir, :memory_git_host_default, {:error, :boom})
      assert GitHost.pr_merged?(nil, "https://github.com/x/y/pull/2") == {:error, :boom}
    end

    test "normalizes a bare boolean response to an ok-tuple" do
      url = "https://github.com/Identione/symphony/pull/11"
      Application.put_env(:symphony_elixir, :memory_git_host_pr_merged, %{url => true})

      assert GitHost.pr_merged?(nil, url) == {:ok, true}
    end
  end
end
