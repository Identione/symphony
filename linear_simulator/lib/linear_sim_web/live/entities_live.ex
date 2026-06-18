defmodule LinearSimWeb.EntitiesLive do
  @moduledoc "Browser over the simulator's current seeded entities."
  use LinearSimWeb, :live_view

  alias LinearSim.Linear

  @tabs [
    {:issues, "Issues"},
    {:projects, "Projects"},
    {:teams, "Teams"},
    {:states, "Workflow States"},
    {:users, "Users"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Entities")
     |> assign(:tab, :issues)
     |> assign(:query, "")
     |> assign(:state_filter, "")
     |> assign_shell(:entities)
     |> assign_data()}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) do
    {:noreply, socket |> assign(:tab, String.to_existing_atom(tab)) |> assign_data()}
  end

  def handle_event("filter", %{"query" => query, "state" => state}, socket) do
    {:noreply, socket |> assign(query: query, state_filter: state) |> assign_data()}
  end

  @impl true
  def handle_info(:sim_changed, socket), do: {:noreply, assign_data(socket)}

  defp assign_data(socket) do
    org = Linear.default_organization()

    socket
    |> assign(:org, org)
    |> assign(:states, Linear.list_workflow_states(org))
    |> assign(
      :rows,
      rows(org, socket.assigns.tab, socket.assigns.query, socket.assigns.state_filter)
    )
  end

  defp rows(org, :issues, query, state_filter) do
    org
    |> Linear.list_issues(%{})
    |> Enum.filter(&issue_matches?(&1, query, state_filter))
  end

  defp rows(org, :projects, _q, _s), do: Linear.list_projects(org, %{})
  defp rows(org, :teams, _q, _s), do: Linear.list_teams(org)
  defp rows(org, :states, _q, _s), do: Linear.list_workflow_states(org)
  defp rows(org, :users, _q, _s), do: Linear.list_users(org)

  defp issue_matches?(issue, query, state_filter) do
    text = String.downcase("#{issue.identifier} #{issue.title}")
    query_ok = query == "" or String.contains?(text, String.downcase(query))
    state_ok = state_filter == "" or (issue.state && issue.state.name == state_filter)
    query_ok and state_ok
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <.shell active={@active} scenario={@scenario} mode={@mode} capturing={@capturing}>
      <h2 class="text-xl font-bold mb-4">Entities Browser</h2>

      <div class="flex items-center gap-4 mb-4 border-b border-outline-variant">
        <button
          :for={{tab, label} <- @tabs}
          phx-click="tab"
          phx-value-tab={tab}
          class={[
            "pb-2 text-[13px] font-semibold transition-colors -mb-px border-b-2",
            @tab == tab && "text-primary border-primary" || "text-on-surface-variant border-transparent hover:text-on-surface"
          ]}
        >
          {label}
        </button>
      </div>

      <form :if={@tab == :issues} id="issue-filter" phx-change="filter" class="flex flex-wrap items-center gap-3 mb-4">
        <div class="relative flex-1 min-w-[240px]">
          <span class="material-symbols-outlined absolute left-3 top-1/2 -translate-y-1/2 text-on-surface-variant text-lg">search</span>
          <input
            type="text"
            name="query"
            value={@query}
            phx-debounce="200"
            placeholder="Search issues..."
            class="w-full bg-surface-container-lowest border border-outline-variant rounded pl-10 pr-4 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
          />
        </div>
        <select name="state" class="bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] text-on-surface-variant focus:border-primary focus:ring-0 outline-none">
          <option value="" selected={@state_filter == ""}>All States</option>
          <option :for={state <- @states} value={state.name} selected={@state_filter == state.name}>{state.name}</option>
        </select>
      </form>

      <div class="bg-surface-container-low border border-outline-variant rounded-lg overflow-hidden">
        <.issues_table :if={@tab == :issues} rows={@rows} />
        <.projects_table :if={@tab == :projects} rows={@rows} />
        <.teams_table :if={@tab == :teams} rows={@rows} />
        <.states_table :if={@tab == :states} rows={@rows} />
        <.users_table :if={@tab == :users} rows={@rows} />
        <p :if={@rows == []} class="px-4 py-8 text-center text-on-surface-variant text-[13px]">No rows for this scenario.</p>
      </div>
    </.shell>
    """
  end

  attr :rows, :list, required: true

  defp issues_table(assigns) do
    ~H"""
    <table :if={@rows != []} class="w-full text-left">
      <thead class="bg-surface-container-lowest">
        <tr class="border-b border-outline-variant">
          <.th>Identifier</.th><.th>Title</.th><.th>State</.th><.th>Assignee</.th><.th>Branch</.th><.th>Updated</.th>
        </tr>
      </thead>
      <tbody class="divide-y divide-outline-variant">
        <tr :for={issue <- @rows} class="hover:bg-surface-variant/20 transition-colors">
          <td class="px-4 py-3 font-mono text-[13px] text-primary">{issue.identifier}</td>
          <td class="px-4 py-3 text-[14px]">{issue.title}</td>
          <td class="px-4 py-3"><.state_pill state={issue.state} /></td>
          <td class="px-4 py-3 text-[13px] text-on-surface-variant">{assignee_name(issue.assignee)}</td>
          <td class="px-4 py-3 font-mono text-xs text-on-surface-variant">{issue.branch_name || "-"}</td>
          <td class="px-4 py-3 text-[13px] text-on-surface-variant">{format_time(issue.updated_at)}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :rows, :list, required: true

  defp projects_table(assigns) do
    ~H"""
    <table :if={@rows != []} class="w-full text-left">
      <thead class="bg-surface-container-lowest"><tr class="border-b border-outline-variant"><.th>Name</.th><.th>Slug</.th><.th>ID</.th></tr></thead>
      <tbody class="divide-y divide-outline-variant">
        <tr :for={p <- @rows} class="hover:bg-surface-variant/20">
          <td class="px-4 py-3 text-[14px]">{p.name}</td>
          <td class="px-4 py-3 font-mono text-[13px] text-primary">{p.slug_id}</td>
          <td class="px-4 py-3 font-mono text-xs text-on-surface-variant">{p.id}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :rows, :list, required: true

  defp teams_table(assigns) do
    ~H"""
    <table :if={@rows != []} class="w-full text-left">
      <thead class="bg-surface-container-lowest"><tr class="border-b border-outline-variant"><.th>Key</.th><.th>Name</.th><.th>ID</.th></tr></thead>
      <tbody class="divide-y divide-outline-variant">
        <tr :for={t <- @rows} class="hover:bg-surface-variant/20">
          <td class="px-4 py-3 font-mono text-[13px] text-primary">{t.key}</td>
          <td class="px-4 py-3 text-[14px]">{t.name}</td>
          <td class="px-4 py-3 font-mono text-xs text-on-surface-variant">{t.id}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :rows, :list, required: true

  defp states_table(assigns) do
    ~H"""
    <table :if={@rows != []} class="w-full text-left">
      <thead class="bg-surface-container-lowest"><tr class="border-b border-outline-variant"><.th>Name</.th><.th>Type</.th><.th>Position</.th></tr></thead>
      <tbody class="divide-y divide-outline-variant">
        <tr :for={s <- @rows} class="hover:bg-surface-variant/20">
          <td class="px-4 py-3"><.state_pill state={s} /></td>
          <td class="px-4 py-3 font-mono text-[13px] text-on-surface-variant">{s.type}</td>
          <td class="px-4 py-3 font-mono text-[13px] text-on-surface-variant">{s.position}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :rows, :list, required: true

  defp users_table(assigns) do
    ~H"""
    <table :if={@rows != []} class="w-full text-left">
      <thead class="bg-surface-container-lowest"><tr class="border-b border-outline-variant"><.th>Name</.th><.th>Email</.th><.th>ID</.th></tr></thead>
      <tbody class="divide-y divide-outline-variant">
        <tr :for={u <- @rows} class="hover:bg-surface-variant/20">
          <td class="px-4 py-3 text-[14px]">{u.name}</td>
          <td class="px-4 py-3 text-[13px] text-on-surface-variant">{u.email}</td>
          <td class="px-4 py-3 font-mono text-xs text-on-surface-variant">{u.id}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  slot :inner_block, required: true

  defp th(assigns) do
    ~H"""
    <th class="px-4 py-3 text-[11px] font-semibold uppercase tracking-wide text-on-surface-variant">{render_slot(@inner_block)}</th>
    """
  end

  attr :state, :any, required: true

  defp state_pill(%{state: nil} = assigns) do
    ~H"""
    <span class="text-on-surface-variant text-xs">—</span>
    """
  end

  defp state_pill(assigns) do
    {dot, text} = state_colors(assigns.state.type)
    assigns = assign(assigns, dot: dot, text: text)

    ~H"""
    <span class={["inline-flex items-center gap-2 px-2 py-0.5 rounded-full w-fit border", @text]}>
      <span class={["w-1.5 h-1.5 rounded-full", @dot]}></span>
      <span class="text-[10px] font-bold uppercase">{@state.name}</span>
    </span>
    """
  end

  defp state_colors("completed"),
    do: {"bg-emerald-500", "bg-emerald-500/10 text-emerald-400 border-emerald-500/20"}

  defp state_colors("started"),
    do: {"bg-amber-500", "bg-amber-500/10 text-amber-400 border-amber-500/20"}

  defp state_colors("canceled"),
    do: {"bg-red-500", "bg-red-500/10 text-red-400 border-red-500/20"}

  defp state_colors(_),
    do:
      {"bg-on-surface-variant",
       "bg-on-surface-variant/10 text-on-surface-variant border-on-surface-variant/20"}

  defp assignee_name(nil), do: "Unassigned"
  defp assignee_name(%{name: name}), do: name

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
