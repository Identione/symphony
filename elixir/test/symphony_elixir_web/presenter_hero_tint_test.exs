defmodule SymphonyElixirWeb.PresenterHeroTintTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixirWeb.HeroTint
  alias SymphonyElixirWeb.Presenter

  defmodule FakeSnapshotServer do
    use GenServer

    def start_link(name) do
      GenServer.start_link(__MODULE__, :ok, name: name)
    end

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call(:snapshot, _from, state) do
      {:reply, empty_snapshot(), state}
    end

    defp empty_snapshot do
      %{
        running: [],
        retrying: [],
        blocked: [],
        codex_totals: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
        claude_totals: %{
          input_tokens: 0,
          output_tokens: 0,
          total_tokens: 0,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 0,
          seconds_running: 0
        },
        rate_limits: nil
      }
    end
  end

  test "state_payload exposes a hero_tint derived from the configured project slug" do
    server_name = Module.concat(__MODULE__, :Server)
    {:ok, pid} = FakeSnapshotServer.start_link(server_name)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :normal) end)

    payload = Presenter.state_payload(server_name, 1_000)

    assert payload.linear_project == "project"
    assert payload.hero_tint == HeroTint.inline_style("project")
    assert payload.hero_tint =~ "--hero-tint-bg:"
    assert payload.hero_tint =~ "--hero-tint-border:"
  end
end
