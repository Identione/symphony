defmodule SymphonyElixir.StatusDashboardTerminalGateTest do
  @moduledoc """
  Covers the TTY gate that stops the full-screen dashboard from appending ANSI
  frames to a non-terminal stdout (IDE-307). The terminal predicate is injected
  via the `:terminal_capable` option so the gate is exercised deterministically;
  real `:io.columns/0` detection under `nohup`/redirection is verified live, not
  here (see the issue's TDD notes).
  """
  use SymphonyElixir.TestSupport

  defp dashboard_name(suffix), do: Module.concat(__MODULE__, suffix)

  defp start_dashboard!(opts) do
    parent = self()

    default = [
      render_fun: fn content -> send(parent, {:render, content}) end
    ]

    {:ok, pid} = StatusDashboard.start_link(Keyword.merge(default, opts))

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    pid
  end

  describe "compute_enabled/2 resolution" do
    test "explicit false disables regardless of terminal capability" do
      assert StatusDashboard.compute_enabled(false, fn -> true end) == false
    end

    test "explicit true enables even without a terminal (explicit config wins)" do
      assert StatusDashboard.compute_enabled(true, fn -> false end) == true
    end

    test "unset (nil) defers to the terminal predicate" do
      assert StatusDashboard.compute_enabled(nil, fn -> true end) == true
      assert StatusDashboard.compute_enabled(nil, fn -> false end) == false
    end
  end

  describe "non-TTY stdout (default config, unset dashboard_enabled)" do
    test "resolves disabled and never invokes the renderer even as the poll countdown changes" do
      pid =
        start_dashboard!(
          name: dashboard_name(:NonTty),
          terminal_capable: fn -> false end,
          refresh_ms: 50
        )

      assert %{enabled: false} = :sys.get_state(pid)

      # Simulate the per-second "Next refresh: Ns" countdown ticking across
      # snapshots plus explicit refresh notifications. A disabled process must
      # take no snapshots and emit no frames at all.
      for _ <- 1..5 do
        :sys.replace_state(pid, fn state ->
          %{state | last_snapshot_fingerprint: :force_change, last_rendered_content: nil}
        end)

        StatusDashboard.notify_update(dashboard_name(:NonTty))
        send(pid, :tick)
      end

      refute_receive {:render, _content}, 300
    end
  end

  describe "TTY stdout" do
    test "resolves enabled and emits a full ANSI frame" do
      start_dashboard!(
        name: dashboard_name(:Tty),
        terminal_capable: fn -> true end,
        refresh_ms: 60_000
      )

      StatusDashboard.notify_update(dashboard_name(:Tty))

      assert_receive {:render, content}, 2_000
      assert content =~ "\e["
    end

    test "identical content is not re-rendered (dedup path intact)" do
      start_dashboard!(
        name: dashboard_name(:Dedup),
        terminal_capable: fn -> true end,
        refresh_ms: 60_000,
        render_interval_ms: 1
      )

      StatusDashboard.notify_update(dashboard_name(:Dedup))
      assert_receive {:render, _first}, 2_000

      # Same snapshot -> same formatted content -> dedup drops the frame.
      StatusDashboard.notify_update(dashboard_name(:Dedup))
      StatusDashboard.notify_update(dashboard_name(:Dedup))

      refute_receive {:render, _second}, 200
    end
  end

  describe "render_offline_status/1 shutdown guard" do
    test "emits nothing when stdout is not a terminal" do
      parent = self()

      assert :ok =
               StatusDashboard.render_offline_status(
                 terminal_capable: fn -> false end,
                 render_fun: fn content -> send(parent, {:offline, content}) end
               )

      refute_receive {:offline, _content}, 100
    end

    test "emits the offline frame when stdout is a terminal" do
      parent = self()

      assert :ok =
               StatusDashboard.render_offline_status(
                 terminal_capable: fn -> true end,
                 render_fun: fn content -> send(parent, {:offline, content}) end
               )

      assert_receive {:offline, content}, 100
      assert content =~ "offline"
    end
  end
end
