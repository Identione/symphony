defmodule LinearSimWeb.ScenariosLive do
  @moduledoc "Control panel: load a data scenario or force a GraphQL response mode."
  use LinearSimWeb, :live_view

  alias LinearSim.{Mode, Scenarios}

  @scenarios [
    {"basic_workspace", :data,
     "One org, one team, one project, one Todo issue (ENG-1). The default."},
    {"empty_workspace", :data, "Base workspace with zero issues."},
    {"many_issues", :data, "75 issues (ENG-1 through ENG-75) for pagination testing."},
    {"archived_issues", :data, "One active issue plus one archived Done issue."},
    {"webhook_demo", :data, "Basic workspace used as the source state for webhook replay demos."},
    {"rate_limited", :error,
     "Every request returns HTTP 200 with an errors array (type RATELIMITED)."},
    {"invalid_token", :error, "Every request returns an AUTHENTICATION_ERROR."},
    {"permission_denied", :error, "Every request returns a FORBIDDEN error."}
  ]

  @modes [
    {:normal, "Normal"},
    {:rate_limited, "Rate limited"},
    {:invalid_token, "Invalid token"},
    {:permission_denied, "Permission denied"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Scenarios")
     |> assign_shell(:scenarios)}
  end

  @impl true
  def handle_event("load", %{"name" => name}, socket) do
    :ok = Scenarios.load!(name)
    notify_changed()
    {:noreply, assign_status(socket)}
  end

  def handle_event("set_mode", %{"mode" => mode}, socket) do
    Mode.put(String.to_existing_atom(mode))
    notify_changed()
    {:noreply, assign_status(socket)}
  end

  @impl true
  def handle_info(:sim_changed, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, scenarios: @scenarios, modes: @modes)

    ~H"""
    <.shell active={@active} scenario={@scenario} mode={@mode} capturing={@capturing}>
      <h2 class="text-xl font-bold mb-4">Scenario Control Panel</h2>

      <div class="bg-surface-container-low border border-outline-variant rounded-lg p-4 mb-4">
        <label class="text-[11px] font-semibold uppercase tracking-wide text-on-surface-variant mb-1 block">
          Response mode override
        </label>
        <p class="text-[13px] text-on-surface-variant mb-3">
          Forces every GraphQL request to return that error in the response body (HTTP 200).
        </p>
        <div class="flex flex-wrap bg-surface-container-lowest p-1 rounded border border-outline-variant w-fit">
          <button
            :for={{mode, label} <- @modes}
            phx-click="set_mode"
            phx-value-mode={mode}
            class={[
              "px-4 py-1.5 text-xs rounded transition-colors",
              @mode == mode && "bg-primary text-on-primary font-bold" ||
                "text-on-surface-variant hover:text-on-surface font-medium"
            ]}
          >
            {String.upcase(label)}
          </button>
        </div>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4">
        <div
          :for={{name, type, desc} <- @scenarios}
          class={[
            "bg-surface-container-low p-4 rounded-lg relative flex flex-col",
            @scenario == name && "border-2 border-primary" || "border border-outline-variant hover:border-primary/50 transition-colors"
          ]}
        >
          <div class="absolute top-2 right-2 flex items-center gap-2">
            <span :if={type == :error} class="px-2 py-0.5 bg-red-500/20 text-red-400 rounded-full text-[10px] font-bold">ERROR</span>
            <span :if={type == :data} class="px-2 py-0.5 bg-surface-container-highest text-on-surface-variant rounded-full text-[10px] font-bold">DATA</span>
            <span :if={@scenario == name} class="flex items-center gap-1 px-2 py-0.5 bg-primary/20 text-primary rounded-full text-[10px] font-bold">
              <span class="w-1.5 h-1.5 bg-primary rounded-full"></span> ACTIVE
            </span>
          </div>
          <h4 class="font-mono text-sm font-bold mb-1 mt-1">{name}</h4>
          <p class="text-on-surface-variant text-[13px] mb-4 leading-relaxed">{desc}</p>
          <button
            :if={@scenario != name}
            phx-click="load"
            phx-value-name={name}
            class="mt-auto w-full py-2 bg-primary text-on-primary text-[11px] font-bold uppercase tracking-wide rounded hover:brightness-110 transition"
          >
            Load scenario
          </button>
          <div :if={@scenario == name} class="mt-auto w-full py-2 bg-surface-container-highest border border-outline-variant text-on-surface-variant text-[11px] font-bold uppercase tracking-wide text-center rounded">
            Loaded
          </div>
        </div>
      </div>
    </.shell>
    """
  end
end
