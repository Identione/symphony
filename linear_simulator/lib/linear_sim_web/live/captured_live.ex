defmodule LinearSimWeb.CapturedLive do
  @moduledoc "Master-detail feed of captured GraphQL operations, with promote/clear."
  use LinearSimWeb, :live_view

  alias LinearSim.OperationCapture

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Captured Operations")
     |> assign(:flash_note, nil)
     |> assign_shell(:captured)
     |> assign_data(nil)}
  end

  @impl true
  def handle_event("select", %{"basename" => basename}, socket) do
    {:noreply, assign(socket, :selected, find(socket.assigns.captures, basename))}
  end

  def handle_event("clear", _params, socket) do
    count = OperationCapture.clear()

    {:noreply,
     socket |> assign(:flash_note, "Cleared #{count} captured operation(s).") |> assign_data(nil)}
  end

  def handle_event("promote", %{"basename" => basename}, socket) do
    note =
      case OperationCapture.promote(basename) do
        {:ok, dest} -> "Promoted to #{dest}"
        {:error, reason} -> "Promote failed: #{inspect(reason)}"
      end

    {:noreply, assign(socket, :flash_note, note)}
  end

  @impl true
  def handle_info(:sim_changed, socket), do: {:noreply, socket}

  defp assign_data(socket, keep_selected) do
    captures = OperationCapture.list()
    selected = (keep_selected && find(captures, keep_selected)) || List.first(captures)
    assign(socket, captures: captures, selected: selected)
  end

  defp find(captures, basename), do: Enum.find(captures, &(&1.basename == basename))

  @impl true
  def render(assigns) do
    ~H"""
    <.shell active={@active} scenario={@scenario} mode={@mode} capturing={@capturing} unsupported_count={@unsupported_count} show_unsupported={@show_unsupported} unsupported_entries={@unsupported_entries}>
      <div class="flex items-center justify-between mb-4">
        <div class="flex items-center gap-3">
          <h2 class="text-xl font-bold">Captured Operations</h2>
          <span class={[
            "px-2 py-0.5 rounded-full text-[10px] font-bold uppercase tracking-wide",
            @capturing && "bg-emerald-500/10 text-emerald-400" || "bg-surface-container-highest text-on-surface-variant"
          ]}>
            {@capturing && "capturing live" || "capture off"}
          </span>
        </div>
        <button phx-click="clear" class="text-[13px] text-red-400 hover:underline flex items-center gap-1">
          <span class="material-symbols-outlined text-sm">delete_sweep</span> Clear captures
        </button>
      </div>

      <p :if={@flash_note} class="mb-3 text-[13px] text-primary font-mono">{@flash_note}</p>

      <div :if={@captures == []} class="bg-surface-container-low border border-outline-variant rounded-lg p-8 text-center text-on-surface-variant text-[13px]">
        No operations captured yet. Toggle <span class="font-semibold text-on-surface">Capture ops</span> on, then send GraphQL traffic to <span class="font-mono">/graphql</span>.
      </div>

      <div :if={@captures != []} class="grid grid-cols-12 gap-4 h-[460px]">
        <div class="col-span-12 lg:col-span-4 bg-surface-container-low border border-outline-variant rounded-lg overflow-y-auto">
          <div class="divide-y divide-outline-variant">
            <button
              :for={cap <- @captures}
              phx-click="select"
              phx-value-basename={cap.basename}
              class={[
                "w-full text-left p-3 transition-colors",
                @selected && @selected.basename == cap.basename && "bg-primary/10 border-l-2 border-primary" || "hover:bg-surface-variant/20"
              ]}
            >
              <div class="flex justify-between items-start mb-1">
                <span class="font-mono text-[13px] text-on-surface">{cap.operation_name}</span>
                <span class="text-[10px] text-on-surface-variant">{cap.captured_at}</span>
              </div>
              <span class="px-1.5 py-0.5 bg-surface-container-highest text-[10px] font-bold rounded uppercase">{cap.kind}</span>
            </button>
          </div>
        </div>

        <div class="col-span-12 lg:col-span-8 bg-surface-container-lowest border border-outline-variant rounded-lg p-4 flex flex-col">
          <div class="flex items-center justify-between mb-3 flex-none">
            <h3 class="font-mono text-[13px] text-on-surface">Details: {@selected.operation_name}</h3>
            <button
              phx-click="promote"
              phx-value-basename={@selected.basename}
              class="px-3 py-1.5 bg-primary text-on-primary text-[11px] font-bold uppercase tracking-wide rounded hover:brightness-110 transition flex items-center gap-2"
            >
              <span class="material-symbols-outlined text-sm">move_up</span> Promote to curated corpus
            </button>
          </div>
          <div class="flex-1 overflow-auto space-y-4">
            <div>
              <p class="text-[11px] font-semibold uppercase tracking-wide text-on-surface-variant mb-2">GraphQL operation</p>
              <pre class="font-mono text-xs text-on-surface-variant leading-relaxed bg-background p-4 rounded border border-outline-variant overflow-auto whitespace-pre-wrap">{@selected.query}</pre>
            </div>
            <div :if={@selected.variables}>
              <p class="text-[11px] font-semibold uppercase tracking-wide text-on-surface-variant mb-2">Variables (redacted)</p>
              <pre class="font-mono text-xs text-on-surface-variant leading-relaxed bg-background p-4 rounded border border-outline-variant overflow-auto whitespace-pre-wrap">{@selected.variables}</pre>
            </div>
          </div>
        </div>
      </div>
    </.shell>
    """
  end
end
