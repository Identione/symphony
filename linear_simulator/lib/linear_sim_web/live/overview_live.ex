defmodule LinearSimWeb.OverviewLive do
  @moduledoc "Landing dashboard: live entity counts and current simulator state."
  use LinearSimWeb, :live_view

  alias LinearSim.Linear

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign_shell(:overview)
     |> assign_data()}
  end

  @impl true
  def handle_info(:sim_changed, socket), do: {:noreply, assign_data(socket)}

  defp assign_data(socket), do: assign(socket, :counts, Linear.counts())

  @stats [
    {:organizations, "Orgs"},
    {:users, "Users"},
    {:teams, "Teams"},
    {:projects, "Projects"},
    {:issues, "Issues"},
    {:comments, "Comments"},
    {:workflow_states, "States"},
    {:webhook_deliveries, "Deliveries"}
  ]

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :stats, @stats)

    ~H"""
    <.shell active={@active} scenario={@scenario} mode={@mode} capturing={@capturing} unsupported_count={@unsupported_count} show_unsupported={@show_unsupported} unsupported_entries={@unsupported_entries}>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-xl font-bold">Overview</h2>
        <span class="flex items-center gap-2 text-[11px] font-semibold uppercase tracking-wide text-on-surface-variant">
          <span class="w-1.5 h-1.5 rounded-full bg-emerald-500"></span> Simulator online
        </span>
      </div>

      <div class="grid grid-cols-2 md:grid-cols-4 lg:grid-cols-8 gap-2 mb-8">
        <div :for={{key, label} <- @stats} class="bg-surface-container-low border border-outline-variant rounded-lg p-4">
          <p class="text-[11px] font-semibold uppercase tracking-wide text-on-surface-variant mb-2">{label}</p>
          <p class="font-mono text-2xl font-bold text-primary">{@counts[key]}</p>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div class="bg-surface-container-low border border-outline-variant rounded-lg p-4">
          <h3 class="text-[11px] font-semibold uppercase tracking-wide text-on-surface mb-4 flex items-center gap-2">
            <span class="material-symbols-outlined text-primary text-base">cloud_sync</span> Current state
          </h3>
          <div class="space-y-1">
            <div class="flex justify-between items-center py-2 border-b border-outline-variant">
              <span class="text-on-surface-variant text-[13px]">Active scenario</span>
              <span class="font-mono text-xs text-primary px-2 py-0.5 bg-primary/10 border border-primary/20 rounded">{String.upcase(@scenario)}</span>
            </div>
            <div class="flex justify-between items-center py-2 border-b border-outline-variant">
              <span class="text-on-surface-variant text-[13px]">Response mode</span>
              <.mode_pill mode={@mode} />
            </div>
            <div class="flex justify-between items-center py-2 border-b border-outline-variant">
              <span class="text-on-surface-variant text-[13px]">Operation capture</span>
              <span class="font-mono text-xs">{@capturing && "enabled" || "disabled"}</span>
            </div>
            <div class="flex justify-between items-center py-2">
              <span class="text-on-surface-variant text-[13px]">Unsupported ops</span>
              <span class={[
                "font-mono text-xs px-2 py-0.5 rounded border",
                @unsupported_count > 0 && "text-red-400 bg-red-500/10 border-red-500/20" ||
                  "text-on-surface-variant border-outline-variant"
              ]}>
                {@unsupported_count}
              </span>
            </div>
          </div>
        </div>

        <div class="bg-surface-container-low border border-outline-variant rounded-lg p-4">
          <h3 class="text-[11px] font-semibold uppercase tracking-wide text-on-surface mb-4 flex items-center gap-2">
            <span class="material-symbols-outlined text-primary text-base">bolt</span> Quick links
          </h3>
          <div class="space-y-2 text-[13px]">
            <.link navigate="/scenarios" class="flex items-center gap-3 py-1 text-on-surface-variant hover:text-primary">
              <span class="material-symbols-outlined text-sm">play_circle</span> Switch scenario or force an error mode
            </.link>
            <.link navigate="/entities" class="flex items-center gap-3 py-1 text-on-surface-variant hover:text-primary">
              <span class="material-symbols-outlined text-sm">database</span> Browse seeded issues, teams and states
            </.link>
            <.link navigate="/webhooks" class="flex items-center gap-3 py-1 text-on-surface-variant hover:text-primary">
              <span class="material-symbols-outlined text-sm">webhook</span> Replay a webhook to your app
            </.link>
            <a href="/admin/state" class="flex items-center gap-3 py-1 text-on-surface-variant hover:text-primary">
              <span class="material-symbols-outlined text-sm">data_object</span> Raw /admin/state JSON
            </a>
          </div>
        </div>
      </div>
    </.shell>
    """
  end
end
