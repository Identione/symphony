defmodule LinearSimWeb.SettingsLive do
  @moduledoc "Runtime configuration: operation capture, GraphQL logging, endpoints, danger zone."
  use LinearSimWeb, :live_view

  alias LinearSim.{OperationCapture, Scenarios}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:note, nil)
     |> assign_shell(:settings)
     |> assign_config()}
  end

  @impl true
  def handle_event("toggle", %{"group" => group, "field" => field}, socket) do
    key = group_key(group)
    config = Application.get_env(:linear_sim, key, [])
    field_atom = String.to_existing_atom(field)
    flipped = Keyword.put(config, field_atom, not Keyword.get(config, field_atom, false))
    Application.put_env(:linear_sim, key, flipped)
    notify_changed()
    {:noreply, socket |> assign_config() |> assign_status()}
  end

  def handle_event("wipe", _params, socket) do
    :ok = Scenarios.load!("empty_workspace")
    notify_changed()

    {:noreply,
     socket |> assign(:note, "Workspace emptied (empty_workspace loaded).") |> assign_status()}
  end

  @impl true
  def handle_info(:sim_changed, socket), do: {:noreply, assign_config(socket)}

  defp assign_config(socket) do
    socket
    |> assign(:capture, Application.get_env(:linear_sim, :operation_capture, []))
    |> assign(:logging, Application.get_env(:linear_sim, :graphql_logging, []))
    |> assign(:capture_dir, OperationCapture.directory())
  end

  defp group_key("capture"), do: :operation_capture
  defp group_key("logging"), do: :graphql_logging

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={@active} scenario={@scenario} mode={@mode} capturing={@capturing} unsupported_count={@unsupported_count} show_unsupported={@show_unsupported} unsupported_entries={@unsupported_entries}>
      <h2 class="text-xl font-bold mb-1">Settings</h2>
      <p class="text-[13px] text-on-surface-variant mb-6">Runtime configuration for this simulator instance.</p>
      <p :if={@note} class="mb-4 text-[13px] font-mono text-primary">{@note}</p>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4 mb-4">
        <div class="bg-surface-container-low border border-outline-variant rounded-lg p-4">
          <h3 class="text-[11px] font-semibold uppercase tracking-wide text-on-surface mb-4 flex items-center gap-2">
            <span class="material-symbols-outlined text-primary text-base">data_object</span> Operation capture
          </h3>
          <.toggle_row group="capture" field="enabled" label="Capture incoming operations to disk" on={truthy(@capture, :enabled)} />
          <div class="flex justify-between items-center py-2 border-b border-outline-variant">
            <span class="text-[13px] text-on-surface-variant">Storage path</span>
            <span class="font-mono text-xs">{@capture_dir}</span>
          </div>
          <.toggle_row group="capture" field="include_variables" label="Include variables" on={truthy(@capture, :include_variables)} />
        </div>

        <div class="bg-surface-container-low border border-outline-variant rounded-lg p-4">
          <h3 class="text-[11px] font-semibold uppercase tracking-wide text-on-surface mb-4 flex items-center gap-2">
            <span class="material-symbols-outlined text-primary text-base">terminal</span> GraphQL logging
          </h3>
          <.toggle_row group="logging" field="enabled" label="Enable request logging" on={truthy(@logging, :enabled)} />
          <.toggle_row group="logging" field="log_query" label="Log queries" on={truthy(@logging, :log_query)} />
          <.toggle_row group="logging" field="log_variables" label="Log variables" on={truthy(@logging, :log_variables)} />
          <.toggle_row group="logging" field="redact_authorization" label="Redact Authorization header" on={truthy(@logging, :redact_authorization)} last={true} />
        </div>
      </div>

      <div class="bg-surface-container-low border border-outline-variant rounded-lg p-4 mb-4">
        <h3 class="text-[11px] font-semibold uppercase tracking-wide text-on-surface mb-4 flex items-center gap-2">
          <span class="material-symbols-outlined text-primary text-base">hub</span> Endpoints
        </h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-x-8">
          <.endpoint_row label="GraphQL" value="POST /graphql" />
          <.endpoint_row label="State dump" value="GET /admin/state" />
          <.endpoint_row label="Reset" value="POST /admin/reset" />
          <.endpoint_row label="Bearer token (default)" value="user_hakan" />
        </div>
      </div>

      <div class="bg-surface-container-low border border-red-500/30 rounded-lg p-4">
        <h3 class="text-[11px] font-semibold uppercase tracking-wide text-red-400 mb-2 flex items-center gap-2">
          <span class="material-symbols-outlined text-base">warning</span> Danger zone
        </h3>
        <p class="text-[13px] text-on-surface-variant mb-4">These actions immediately replace the active simulator state.</p>
        <div class="flex gap-3">
          <button phx-click="shell:reset" class="px-4 py-2 border border-red-500/40 text-red-400 rounded text-[13px] font-semibold hover:bg-red-500/10 transition flex items-center gap-2">
            <span class="material-symbols-outlined text-sm">restart_alt</span> Reset to default scenario
          </button>
          <button phx-click="wipe" data-confirm="Empty the workspace?" class="px-4 py-2 border border-red-500/40 text-red-400 rounded text-[13px] font-semibold hover:bg-red-500/10 transition flex items-center gap-2">
            <span class="material-symbols-outlined text-sm">delete_forever</span> Wipe all issues
          </button>
        </div>
      </div>
    </.shell>
    """
  end

  attr :group, :string, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :on, :boolean, required: true
  attr :last, :boolean, default: false

  defp toggle_row(assigns) do
    ~H"""
    <div class={["flex justify-between items-center py-2", !@last && "border-b border-outline-variant"]}>
      <span class="text-[13px] text-on-surface-variant">{@label}</span>
      <button
        phx-click="toggle"
        phx-value-group={@group}
        phx-value-field={@field}
        class={["w-10 h-6 rounded-full p-0.5 transition-colors", @on && "bg-primary-container" || "bg-surface-container-highest"]}
      >
        <span class={["block w-5 h-5 rounded-full bg-on-surface transition-transform", @on && "translate-x-4" || "translate-x-0"]}></span>
      </button>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp endpoint_row(assigns) do
    ~H"""
    <div class="flex flex-col py-2 border-b border-outline-variant">
      <span class="text-[11px] font-semibold uppercase tracking-wide text-on-surface-variant">{@label}</span>
      <span class="font-mono text-[13px] text-on-surface">{@value}</span>
    </div>
    """
  end

  defp truthy(config, field), do: Keyword.get(config, field, false) == true
end
