defmodule LinearSimWeb.EntitiesLive do
  @moduledoc "Browser over the simulator's current seeded entities."
  use LinearSimWeb, :live_view

  alias LinearSim.Linear
  alias LinearSimWeb.Shell

  @priorities [
    {"No priority", "0"},
    {"Urgent", "1"},
    {"High", "2"},
    {"Medium", "3"},
    {"Low", "4"}
  ]

  @relation_types ["blocks", "duplicate", "related", "similar"]

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
     |> assign(:form_action, nil)
     |> assign(:form_issue, nil)
     |> assign(:form_errors, %{})
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

  def handle_event("new_issue", _params, socket) do
    {:noreply,
     assign(socket, form_action: :new, form_issue: blank_issue_form(socket), form_errors: %{})}
  end

  def handle_event("edit_issue", %{"id" => id}, socket) do
    case Linear.get_issue_by_id_or_identifier(socket.assigns.org, id) do
      nil ->
        {:noreply, socket}

      issue ->
        {:noreply,
         assign(socket,
           form_action: :edit,
           form_issue: issue_to_form(issue, socket.assigns.users),
           form_errors: %{}
         )}
    end
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, assign(socket, form_action: nil, form_issue: nil, form_errors: %{})}
  end

  def handle_event("save_issue", %{"issue" => params}, socket) do
    save_issue(socket, socket.assigns.form_action, params)
  end

  def handle_event("delete_issue", %{"id" => id}, socket) do
    case Linear.delete_issue(id) do
      {:ok, _issue} ->
        Shell.notify_changed()
        {:noreply, socket |> put_flash(:info, "Issue deleted.") |> assign_data()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Issue not found.")}
    end
  end

  def handle_event(
        "add_relation",
        %{"relation" => %{"type" => type, "related_issue_id" => rid}},
        socket
      ) do
    if rid in ["", nil] do
      {:noreply, put_flash(socket, :error, "Pick an issue to relate to.")}
    else
      attrs = %{
        "issue_id" => socket.assigns.form_issue["id"],
        "type" => type,
        "related_issue_id" => rid
      }

      case Linear.create_issue_relation(attrs) do
        {:ok, _relation} ->
          Shell.notify_changed()
          {:noreply, socket |> refresh_form_relations() |> assign_data()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not add relation.")}
      end
    end
  end

  def handle_event("remove_relation", %{"id" => id}, socket) do
    Linear.delete_issue_relation(id)
    Shell.notify_changed()
    {:noreply, socket |> refresh_form_relations() |> assign_data()}
  end

  @impl true
  def handle_info(:sim_changed, socket), do: {:noreply, assign_data(socket)}

  defp save_issue(socket, :new, params) do
    case Linear.create_issue(socket.assigns.org, params) do
      {:ok, issue} ->
        Shell.notify_changed()

        {:noreply,
         socket
         |> put_flash(:info, "Created #{issue.identifier}.")
         |> assign(form_action: nil, form_issue: nil, form_errors: %{})
         |> assign_data()}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form_issue: Map.merge(socket.assigns.form_issue, params),
           form_errors: errors(changeset)
         )}
    end
  end

  defp save_issue(socket, :edit, params) do
    id = socket.assigns.form_issue["id"]

    case Linear.update_issue(id, Map.delete(params, "team_id")) do
      {:ok, issue} ->
        Shell.notify_changed()

        {:noreply,
         socket
         |> put_flash(:info, "Updated #{issue.identifier}.")
         |> assign(form_action: nil, form_issue: nil, form_errors: %{})
         |> assign_data()}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Issue not found.")
         |> assign(form_action: nil, form_issue: nil)}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           form_issue: Map.merge(socket.assigns.form_issue, params),
           form_errors: errors(changeset)
         )}
    end
  end

  defp assign_data(socket) do
    org = Linear.default_organization()
    all_issues = Linear.list_issues(org, %{})

    socket
    |> assign(:org, org)
    |> assign(:states, Linear.list_workflow_states(org))
    |> assign(:teams, Linear.list_teams(org))
    |> assign(:users, Linear.list_users(org))
    |> assign(:projects, Linear.list_projects(org, %{}))
    |> assign(:all_labels, Linear.list_labels(org))
    |> assign(:all_issues, all_issues)
    |> assign(
      :rows,
      rows(org, socket.assigns.tab, socket.assigns.query, socket.assigns.state_filter, all_issues)
    )
  end

  defp blank_issue_form(socket) do
    %{
      "id" => nil,
      "title" => "",
      "description" => "",
      "team_id" => default_team_id(socket),
      "state_id" => "",
      "assignee_id" => "",
      "project_id" => "",
      "parent_id" => "",
      "priority" => "",
      "label_ids" => [],
      "relations" => []
    }
  end

  defp issue_to_form(issue, users) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title || "",
      "description" => issue.description || "",
      "team_id" => issue.team_id,
      "state_id" => issue.state_id || "",
      "assignee_id" => issue.assignee_id || "",
      "project_id" => issue.project_id || "",
      "parent_id" => issue.parent_id || "",
      "priority" => (issue.priority && to_string(issue.priority)) || "",
      "label_ids" => Enum.map(issue.labels, & &1.id),
      "relations" => relation_rows(issue),
      "activities" => activity_rows(issue, users)
    }
  end

  defp relation_rows(issue) do
    Enum.map(issue.relations, fn r ->
      %{"id" => r.id, "type" => r.type, "target" => r.related_issue && r.related_issue.identifier}
    end)
  end

  # An issue's activity feed. Comments are the only per-issue activity record in
  # the simulator; newest-first for display.
  defp activity_rows(issue, users) do
    issue.id
    |> Linear.list_comments()
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.map(fn c ->
      %{"body" => c.body, "author" => author_name(c.user_id, users), "at" => c.inserted_at}
    end)
  end

  defp author_name(nil, _users), do: "—"

  defp author_name(user_id, users) do
    case Enum.find(users, &(&1.id == user_id)) do
      nil -> "—"
      user -> user.name
    end
  end

  # After a live relation add/remove, re-read the editing issue so the modal's
  # relations list reflects the change without closing the form.
  defp refresh_form_relations(socket) do
    case socket.assigns.form_issue["id"] do
      nil ->
        socket

      id ->
        case Linear.get_issue_by_id_or_identifier(socket.assigns.org, id) do
          nil ->
            socket

          issue ->
            assign(
              socket,
              :form_issue,
              Map.put(socket.assigns.form_issue, "relations", relation_rows(issue))
            )
        end
    end
  end

  defp default_team_id(socket) do
    case socket.assigns[:teams] || [] do
      [team | _] -> team.id
      [] -> ""
    end
  end

  defp errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp rows(_org, :issues, query, state_filter, all_issues) do
    Enum.filter(all_issues, &issue_matches?(&1, query, state_filter))
  end

  defp rows(org, :projects, _q, _s, _issues), do: Linear.list_projects(org, %{})
  defp rows(org, :teams, _q, _s, _issues), do: Linear.list_teams(org)
  defp rows(org, :states, _q, _s, _issues), do: Linear.list_workflow_states(org)
  defp rows(org, :users, _q, _s, _issues), do: Linear.list_users(org)

  defp issue_matches?(issue, query, state_filter) do
    text = String.downcase("#{issue.identifier} #{issue.title}")
    query_ok = query == "" or String.contains?(text, String.downcase(query))
    state_ok = state_filter == "" or (issue.state && issue.state.name == state_filter)
    query_ok and state_ok
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:tabs, @tabs)
      |> assign(:priorities, @priorities)
      |> assign(:relation_types, @relation_types)

    ~H"""
    <.shell active={@active} scenario={@scenario} mode={@mode} capturing={@capturing} unsupported_count={@unsupported_count} show_unsupported={@show_unsupported} unsupported_entries={@unsupported_entries}>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-xl font-bold">Entities Browser</h2>
        <button
          :if={@tab == :issues}
          phx-click="new_issue"
          class="flex items-center gap-2 text-[13px] font-semibold px-3 py-1.5 bg-primary text-on-primary rounded hover:opacity-90 transition-opacity"
        >
          <span class="material-symbols-outlined text-base">add</span> New issue
        </button>
      </div>

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

      <.issue_form
        :if={@form_action != nil}
        action={@form_action}
        issue={@form_issue}
        errors={@form_errors}
        teams={@teams}
        states={@states}
        users={@users}
        projects={@projects}
        priorities={@priorities}
        labels={@all_labels}
        issues={@all_issues}
        relation_types={@relation_types}
      />
    </.shell>
    """
  end

  attr :rows, :list, required: true

  defp issues_table(assigns) do
    ~H"""
    <table :if={@rows != []} class="w-full text-left">
      <thead class="bg-surface-container-lowest">
        <tr class="border-b border-outline-variant">
          <.th>Identifier</.th><.th>Title</.th><.th>State</.th><.th>Project</.th><.th>Blocking</.th><.th>Assignee</.th><.th>Labels</.th><.th>Branch</.th><.th>Updated</.th><.th>Actions</.th>
        </tr>
      </thead>
      <tbody class="divide-y divide-outline-variant">
        <tr :for={issue <- @rows} class="hover:bg-surface-variant/20 transition-colors">
          <td class="px-4 py-3 font-mono text-[13px]">
            <button
              phx-click="edit_issue"
              phx-value-id={issue.id}
              title="Edit issue"
              class="text-primary hover:underline"
            >
              {issue.identifier}
            </button>
          </td>
          <td class="px-4 py-3 text-[14px]">{issue.title}</td>
          <td class="px-4 py-3"><.state_pill state={issue.state} /></td>
          <td class="px-4 py-3 text-[13px] text-on-surface-variant">{(issue.project && issue.project.name) || "—"}</td>
          <td class="px-4 py-3"><.relation_pills issue={issue} /></td>
          <td class="px-4 py-3 text-[13px] text-on-surface-variant">{assignee_name(issue.assignee)}</td>
          <td class="px-4 py-3"><.label_pills labels={issue.labels} /></td>
          <td class="px-4 py-3 font-mono text-xs text-on-surface-variant">{issue.branch_name || "-"}</td>
          <td class="px-4 py-3 text-[13px] text-on-surface-variant">{format_time(issue.updated_at)}</td>
          <td class="px-4 py-3">
            <div class="flex items-center gap-1">
              <button
                phx-click="edit_issue"
                phx-value-id={issue.id}
                title="Edit issue"
                class="p-1.5 rounded text-on-surface-variant hover:text-primary hover:bg-surface-variant transition-colors"
              >
                <span class="material-symbols-outlined text-base">edit</span>
              </button>
              <button
                phx-click="delete_issue"
                phx-value-id={issue.id}
                data-confirm={"Delete #{issue.identifier}? This cannot be undone."}
                title="Delete issue"
                class="p-1.5 rounded text-on-surface-variant hover:text-red-400 hover:bg-surface-variant transition-colors"
              >
                <span class="material-symbols-outlined text-base">delete</span>
              </button>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  attr :action, :atom, required: true
  attr :issue, :map, required: true
  attr :errors, :map, required: true
  attr :teams, :list, required: true
  attr :states, :list, required: true
  attr :users, :list, required: true
  attr :projects, :list, required: true
  attr :priorities, :list, required: true
  attr :labels, :list, required: true
  attr :issues, :list, required: true
  attr :relation_types, :list, required: true

  defp issue_form(assigns) do
    ~H"""
    <div class="fixed inset-0 z-[60] flex items-center justify-center bg-black/50 p-4" phx-window-keydown="cancel_form" phx-key="Escape">
      <div class="w-full max-w-lg bg-surface-container border border-outline-variant rounded-lg shadow-2xl max-h-[90vh] overflow-y-auto">
        <div class="flex items-center justify-between px-5 py-3 border-b border-outline-variant">
          <h3 class="text-base font-bold">
            {if @action == :new, do: "New issue", else: "Edit #{@issue["identifier"]}"}
          </h3>
          <button phx-click="cancel_form" class="p-1 rounded text-on-surface-variant hover:text-on-surface hover:bg-surface-variant">
            <span class="material-symbols-outlined text-lg">close</span>
          </button>
        </div>

        <form phx-submit="save_issue" class="px-5 py-4 space-y-4">
          <div>
            <.field_label>Title</.field_label>
            <input
              type="text"
              name="issue[title]"
              value={@issue["title"]}
              autofocus
              class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
            />
            <.field_error errors={@errors} field={:title} />
          </div>

          <div>
            <.field_label>Description</.field_label>
            <textarea
              name="issue[description]"
              rows="3"
              class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
            >{@issue["description"]}</textarea>
          </div>

          <div class="grid grid-cols-2 gap-4">
            <div>
              <.field_label>Team</.field_label>
              <select
                name="issue[team_id]"
                disabled={@action == :edit}
                class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none disabled:opacity-60"
              >
                <option :for={team <- @teams} value={team.id} selected={@issue["team_id"] == team.id}>
                  {team.key} — {team.name}
                </option>
              </select>
              <.field_error errors={@errors} field={:team_id} />
            </div>

            <div>
              <.field_label>State</.field_label>
              <select
                name="issue[state_id]"
                class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
              >
                <option value="" selected={@issue["state_id"] == ""}>— None —</option>
                <option :for={state <- @states} value={state.id} selected={@issue["state_id"] == state.id}>
                  {state.name}
                </option>
              </select>
            </div>

            <div>
              <.field_label>Assignee</.field_label>
              <select
                name="issue[assignee_id]"
                class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
              >
                <option value="" selected={@issue["assignee_id"] == ""}>Unassigned</option>
                <option :for={user <- @users} value={user.id} selected={@issue["assignee_id"] == user.id}>
                  {user.name}
                </option>
              </select>
            </div>

            <div>
              <.field_label>Project</.field_label>
              <select
                name="issue[project_id]"
                class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
              >
                <option value="" selected={@issue["project_id"] == ""}>— None —</option>
                <option :for={project <- @projects} value={project.id} selected={@issue["project_id"] == project.id}>
                  {project.name}
                </option>
              </select>
            </div>

            <div>
              <.field_label>Priority</.field_label>
              <select
                name="issue[priority]"
                class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
              >
                <option value="" selected={@issue["priority"] == ""}>— None —</option>
                <option :for={{label, value} <- @priorities} value={value} selected={@issue["priority"] == value}>
                  {label}
                </option>
              </select>
            </div>

            <div>
              <.field_label>Parent (sub-issue of)</.field_label>
              <select
                name="issue[parent_id]"
                class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
              >
                <option value="" selected={@issue["parent_id"] == ""}>— None —</option>
                <option
                  :for={issue <- @issues}
                  :if={issue.id != @issue["id"]}
                  value={issue.id}
                  selected={@issue["parent_id"] == issue.id}
                >
                  {issue.identifier} — {issue.title}
                </option>
              </select>
            </div>
          </div>

          <div>
            <.field_label>Labels</.field_label>
            <%!-- Hidden field so deselecting everything still submits an (empty) list, allowing clear. --%>
            <input type="hidden" name="issue[label_ids][]" value="" />
            <select
              name="issue[label_ids][]"
              multiple
              size={max(min(length(@labels), 5), 2)}
              class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
            >
              <option
                :for={label <- @labels}
                value={label.id}
                selected={label.id in (@issue["label_ids"] || [])}
              >
                {label.name}
              </option>
            </select>
            <p class="mt-1 text-[11px] text-on-surface-variant">Cmd/Ctrl-click to select multiple.</p>
          </div>

          <div class="flex justify-end gap-2 pt-2 border-t border-outline-variant">
            <button type="button" phx-click="cancel_form" class="text-[13px] px-3 py-1.5 border border-outline-variant rounded hover:bg-surface-variant transition-colors">
              Cancel
            </button>
            <button type="submit" class="text-[13px] font-semibold px-3 py-1.5 bg-primary text-on-primary rounded hover:opacity-90 transition-opacity">
              {if @action == :new, do: "Create issue", else: "Save changes"}
            </button>
          </div>
        </form>

        <%!-- Relations live outside the main form (separate <form>) and persist immediately. --%>
        <div :if={@action == :edit} class="px-5 pb-5 pt-1 border-t border-outline-variant">
          <.field_label>Relations</.field_label>
          <ul :if={@issue["relations"] != []} class="space-y-1 mb-2">
            <li
              :for={rel <- @issue["relations"]}
              class="flex items-center justify-between bg-surface-container-lowest border border-outline-variant rounded px-3 py-1.5 text-[13px]"
            >
              <span>
                <span class="font-semibold uppercase text-[10px] text-primary">{rel["type"]}</span>
                <span class="text-on-surface-variant">→</span>
                <span class="font-mono">{rel["target"] || "?"}</span>
              </span>
              <button
                phx-click="remove_relation"
                phx-value-id={rel["id"]}
                title="Remove relation"
                class="p-1 rounded text-on-surface-variant hover:text-red-400 hover:bg-surface-variant"
              >
                <span class="material-symbols-outlined text-sm">close</span>
              </button>
            </li>
          </ul>
          <p :if={@issue["relations"] == []} class="text-[12px] text-on-surface-variant mb-2">No relations yet.</p>

          <form phx-submit="add_relation" class="flex items-center gap-2">
            <select
              name="relation[type]"
              class="bg-surface-container-lowest border border-outline-variant rounded px-2 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
            >
              <option :for={type <- @relation_types} value={type}>{type}</option>
            </select>
            <select
              name="relation[related_issue_id]"
              class="flex-1 bg-surface-container-lowest border border-outline-variant rounded px-2 py-1.5 text-[13px] focus:border-primary focus:ring-0 outline-none"
            >
              <option value="">— pick an issue —</option>
              <option :for={issue <- @issues} :if={issue.id != @issue["id"]} value={issue.id}>
                {issue.identifier} — {issue.title}
              </option>
            </select>
            <button type="submit" class="text-[13px] font-semibold px-3 py-1.5 border border-outline-variant rounded hover:bg-surface-variant transition-colors">
              Add
            </button>
          </form>
        </div>

        <%!-- Read-only activity feed (comments) for the issue being edited. --%>
        <div :if={@action == :edit} class="px-5 pb-5 pt-1 border-t border-outline-variant">
          <.field_label>Activity</.field_label>
          <ul :if={@issue["activities"] != []} class="space-y-2">
            <li
              :for={act <- @issue["activities"]}
              class="bg-surface-container-lowest border border-outline-variant rounded px-3 py-2 text-[13px]"
            >
              <div class="flex items-center justify-between text-[11px] text-on-surface-variant mb-1">
                <span class="font-semibold text-on-surface">{act["author"]}</span>
                <span>{format_time(act["at"])}</span>
              </div>
              <p class="whitespace-pre-wrap text-on-surface-variant">{act["body"]}</p>
            </li>
          </ul>
          <p :if={@issue["activities"] == []} class="text-[12px] text-on-surface-variant">No activity yet.</p>
        </div>
      </div>
    </div>
    """
  end

  slot :inner_block, required: true

  defp field_label(assigns) do
    ~H"""
    <label class="block text-[11px] font-semibold uppercase tracking-wide text-on-surface-variant mb-1">{render_slot(@inner_block)}</label>
    """
  end

  attr :errors, :map, required: true
  attr :field, :atom, required: true

  defp field_error(assigns) do
    ~H"""
    <p :for={msg <- Map.get(@errors, @field, [])} class="mt-1 text-[11px] text-red-400">{msg}</p>
    """
  end

  attr :issue, :map, required: true

  defp relation_pills(assigns) do
    blocked_by =
      for r <- assigns.issue.inverse_relations, r.type == "blocks", do: r.issue.identifier

    blocks =
      for r <- assigns.issue.relations, r.type == "blocks", do: r.related_issue.identifier

    assigns = assign(assigns, blocked_by: blocked_by, blocks: blocks)

    ~H"""
    <div :if={@blocked_by != [] or @blocks != []} class="flex flex-wrap gap-1">
      <span
        :for={id <- @blocked_by}
        class="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-semibold border border-red-400/40 text-red-300 bg-red-400/10"
      >
        blocked by {id}
      </span>
      <span
        :for={id <- @blocks}
        class="inline-flex items-center px-2 py-0.5 rounded-full text-[10px] font-semibold border border-amber-400/40 text-amber-300 bg-amber-400/10"
      >
        blocks {id}
      </span>
    </div>
    <span :if={@blocked_by == [] and @blocks == []} class="text-on-surface-variant text-xs">—</span>
    """
  end

  attr :labels, :list, required: true

  defp label_pills(%{labels: []} = assigns) do
    ~H"""
    <span class="text-on-surface-variant text-xs">—</span>
    """
  end

  defp label_pills(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1">
      <span
        :for={label <- @labels}
        class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-[10px] font-semibold border border-outline-variant"
      >
        <span class="w-1.5 h-1.5 rounded-full" style={"background-color: #{label.color || "#888"}"}></span>
        {label.name}
      </span>
    </div>
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
    # Use the state's real Linear color (hex). The 8-digit suffixes give a faint
    # tinted chip (~10% bg, ~33% border) around a solid dot in the full color.
    assigns = assign(assigns, :color, assigns.state.color || "#8a8f98")

    ~H"""
    <span
      class="inline-flex items-center gap-2 px-2 py-0.5 rounded-full w-fit border"
      style={"border-color: #{@color}55; background-color: #{@color}1a"}
    >
      <span class="w-1.5 h-1.5 rounded-full" style={"background-color: #{@color}"}></span>
      <span class="text-[10px] font-bold uppercase" style={"color: #{@color}"}>{@state.name}</span>
    </span>
    """
  end

  defp assignee_name(nil), do: "Unassigned"
  defp assignee_name(%{name: name}), do: name

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
