defmodule LinearSimWeb.Shell do
  @moduledoc """
  Shared dashboard chrome: the fixed sidebar, top status bar, and footer that
  wrap every LiveView page, plus the cross-page state plumbing.

  `assign_shell/2` seeds the live status assigns (active scenario, response mode,
  capture toggle), subscribes the LiveView to simulator-state changes, and
  attaches hooks so the top bar's "Reset" / "Capture ops" controls and live
  refresh work identically on every page.
  """
  use Phoenix.Component

  import Phoenix.LiveView,
    only: [attach_hook: 4, connected?: 1]

  alias LinearSim.{Mode, OperationCapture, Scenarios}
  alias Phoenix.LiveView.Socket
  alias Phoenix.PubSub

  @topic "sim:state"

  @nav [
    {:overview, "Overview", "/", "grid_view"},
    {:scenarios, "Scenarios", "/scenarios", "play_circle"},
    {:entities, "Entities", "/entities", "database"},
    {:captured, "Captured Operations", "/captured", "history"},
    {:webhooks, "Webhooks", "/webhooks", "webhook"},
    {:settings, "Settings", "/settings", "settings"}
  ]

  @doc """
  Seeds shell assigns, subscribes to state changes, and attaches the shared
  control hooks. Call once from each LiveView's `mount/3` with the page key.
  """
  @spec assign_shell(Socket.t(), atom()) :: Socket.t()
  def assign_shell(socket, active) do
    if connected?(socket), do: PubSub.subscribe(LinearSim.PubSub, @topic)

    socket
    |> assign(:active, active)
    |> assign_status()
    |> attach_hook(:shell_events, :handle_event, &shell_event/3)
    |> attach_hook(:shell_info, :handle_info, &shell_info/2)
  end

  @doc "Re-reads the live status assigns (scenario, mode, capture flag)."
  @spec assign_status(Socket.t()) :: Socket.t()
  def assign_status(socket) do
    socket
    |> assign(:scenario, Scenarios.current())
    |> assign(:mode, Mode.get())
    |> assign(:capturing, OperationCapture.enabled?())
  end

  @doc "Broadcasts that simulator state changed so every open page refreshes."
  @spec notify_changed() :: :ok
  def notify_changed, do: PubSub.broadcast(LinearSim.PubSub, @topic, :sim_changed)

  defp shell_event("shell:reset", _params, socket) do
    :ok = Scenarios.reset!()
    notify_changed()
    {:halt, assign_status(socket)}
  end

  defp shell_event("shell:toggle_capture", _params, socket) do
    toggle_capture()
    notify_changed()
    {:halt, assign_status(socket)}
  end

  defp shell_event(_event, _params, socket), do: {:cont, socket}

  defp shell_info(:sim_changed, socket), do: {:cont, assign_status(socket)}
  defp shell_info(_message, socket), do: {:cont, socket}

  defp toggle_capture do
    config = Application.get_env(:linear_sim, :operation_capture, [])
    flipped = Keyword.put(config, :enabled, not Keyword.get(config, :enabled, false))
    Application.put_env(:linear_sim, :operation_capture, flipped)
  end

  ## Components

  attr :active, :atom, required: true
  attr :scenario, :string, required: true
  attr :mode, :atom, required: true
  attr :capturing, :boolean, default: false
  attr :page_title, :string, default: nil
  slot :inner_block, required: true

  @doc "Renders the full dashboard chrome around the page body."
  def shell(assigns) do
    assigns = assign(assigns, :nav, @nav)

    ~H"""
    <div class="flex h-screen overflow-hidden bg-background text-on-surface">
      <aside class="fixed left-0 top-0 h-screen w-[240px] flex flex-col py-4 px-2 z-40 bg-surface-container-low border-r border-outline-variant">
        <div class="mb-8 px-2 flex items-center gap-3">
          <div class="w-8 h-8 rounded bg-primary-container flex items-center justify-center text-on-primary-container">
            <span class="material-symbols-outlined text-lg">terminal</span>
          </div>
          <div>
            <h1 class="text-base font-bold text-primary leading-tight">Linear Simulator</h1>
            <p class="text-[11px] text-on-surface-variant">Control Panel</p>
          </div>
        </div>

        <nav class="flex-1 space-y-1">
          <.nav_link :for={{key, label, path, icon} <- @nav} active={@active} key={key} path={path} icon={icon} label={label} />
        </nav>

        <div class="mt-auto pt-6 border-t border-outline-variant space-y-2">
          <a href="/graphql" class="w-full block text-center py-2 bg-surface-container-highest rounded border border-outline-variant text-on-surface font-mono text-xs hover:bg-surface-variant transition-colors">
            GraphQL: /graphql
          </a>
          <a href="/health" class="flex items-center gap-3 px-3 py-1 text-on-surface-variant hover:text-primary transition-colors text-[13px]">
            <span class="material-symbols-outlined text-sm">monitor_heart</span><span>Health</span>
          </a>
        </div>
      </aside>

      <main class="flex-1 ml-[240px] flex flex-col h-screen overflow-hidden">
        <header class="flex justify-between items-center w-full px-6 h-12 z-50 bg-surface-container border-b border-outline-variant">
          <div class="flex items-center gap-4">
            <span class="text-base font-bold text-on-surface">Linear Simulator</span>
            <div class="h-4 w-px bg-outline-variant"></div>
            <span class="font-mono text-xs text-primary px-2 py-0.5 bg-primary/10 border border-primary/20 rounded">{String.upcase(@scenario)}</span>
            <.mode_pill mode={@mode} />
          </div>
          <div class="flex items-center gap-3">
            <span class="flex items-center gap-1.5 text-[11px] font-semibold text-on-surface-variant">
              <span class="w-2 h-2 rounded-full bg-emerald-500"></span> API :4000
            </span>
            <button phx-click="shell:reset" class="text-[13px] px-3 py-1 border border-outline-variant rounded hover:bg-surface-variant transition-colors">
              Reset to default
            </button>
            <button phx-click="shell:toggle_capture" class={[
              "text-[13px] px-3 py-1 rounded font-semibold transition-colors flex items-center gap-2",
              @capturing && "bg-primary text-on-primary" || "border border-outline-variant text-on-surface-variant hover:bg-surface-variant"
            ]}>
              <span class={["w-1.5 h-1.5 rounded-full", @capturing && "bg-on-primary" || "bg-on-surface-variant"]}></span>
              Capture ops {@capturing && "on" || "off"}
            </button>
          </div>
        </header>

        <div class="flex-1 overflow-y-auto p-6 bg-background">
          {render_slot(@inner_block)}
        </div>

        <footer class="flex justify-between items-center px-6 h-8 z-30 bg-surface-container-lowest border-t border-outline-variant text-secondary">
          <span class="font-mono text-xs">linear_sim • {db_name()} • <span class="text-emerald-500">CONNECTED</span></span>
          <div class="flex items-center gap-4 text-[11px] font-semibold">
            <a href="/health" class="text-on-surface-variant hover:text-primary transition-colors">Health</a>
            <a href="/admin/state" class="text-on-surface-variant hover:text-primary transition-colors">/admin/state</a>
          </div>
        </footer>
      </main>
    </div>
    """
  end

  attr :active, :atom, required: true
  attr :key, :atom, required: true
  attr :path, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link navigate={@path} class={[
      "flex items-center gap-3 px-3 py-2 rounded-lg transition-all text-[11px] font-semibold uppercase tracking-wide",
      @active == @key && "text-primary bg-primary/10 border-l-2 border-primary" ||
        "text-on-surface-variant hover:text-on-surface hover:bg-surface-variant/50"
    ]}>
      <span class="material-symbols-outlined text-sm">{@icon}</span>
      <span>{@label}</span>
    </.link>
    """
  end

  attr :mode, :atom, required: true

  @doc "A colored pill describing the current GraphQL response mode."
  def mode_pill(assigns) do
    {label, classes} = mode_style(assigns.mode)
    assigns = assign(assigns, label: label, classes: classes)

    ~H"""
    <span class={["font-mono text-[11px] font-bold px-2 py-0.5 rounded uppercase", @classes]}>{@label}</span>
    """
  end

  defp mode_style(:normal),
    do: {"normal", "bg-emerald-500/10 text-emerald-400 border border-emerald-500/20"}

  defp mode_style(mode),
    do: {to_string(mode), "bg-red-500/10 text-red-400 border border-red-500/20"}

  defp db_name do
    case Application.get_env(:linear_sim, LinearSim.Repo)[:database] do
      nil -> "linear_sim.db"
      path -> Path.basename(to_string(path))
    end
  end
end
