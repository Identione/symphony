defmodule SymphonyElixir.StatusDashboardTerminalGateTest do
  @moduledoc """
  Covers the tty gate that stops the full-screen dashboard from appending ANSI
  frames to a non-terminal stdout (IDE-307). The probe is injected via the
  `:tty_probe` option so the gate is exercised deterministically; real
  `:prim_tty.isatty/1` detection under `nohup`/redirection is verified live,
  not here.

  Ported from the `terminal_capable`-based variant on PR #125 and adapted to
  the `tty_probe` mechanism this implementation uses.
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

  describe "non-tty stdout (default config, unset dashboard_enabled)" do
    test "resolves disabled and never invokes the renderer even as the poll countdown changes" do
      pid =
        start_dashboard!(
          name: dashboard_name(:NonTty),
          tty_probe: fn -> false end,
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

    test "a probe that raises fails open, so a broken check does not silently kill the dashboard" do
      pid =
        start_dashboard!(
          name: dashboard_name(:ProbeRaises),
          enabled: true,
          tty_probe: fn -> raise "probe unavailable" end,
          refresh_ms: 60_000
        )

      assert %{enabled: true} = :sys.get_state(pid)
    end
  end

  describe "tty stdout" do
    test "resolves enabled and emits a full ANSI frame" do
      start_dashboard!(
        name: dashboard_name(:Tty),
        enabled: true,
        tty_probe: fn -> true end,
        refresh_ms: 60_000
      )

      StatusDashboard.notify_update(dashboard_name(:Tty))

      assert_receive {:render, content}, 2_000
      assert content =~ "\e["
    end
  end

  describe "render_offline_status/1 shutdown guard" do
    test "emits nothing when stdout is not a terminal" do
      parent = self()

      assert :ok =
               StatusDashboard.render_offline_status(
                 tty_probe: fn -> false end,
                 render_fun: fn content -> send(parent, {:offline, content}) end
               )

      refute_receive {:offline, _content}, 100
    end

    test "emits the offline frame when stdout is a terminal" do
      parent = self()

      assert :ok =
               StatusDashboard.render_offline_status(
                 tty_probe: fn -> true end,
                 render_fun: fn content -> send(parent, {:offline, content}) end
               )

      assert_receive {:offline, content}, 100
      assert content =~ "offline"
    end
  end
end
