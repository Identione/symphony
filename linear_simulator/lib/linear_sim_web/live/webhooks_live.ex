defmodule LinearSimWeb.WebhooksLive do
  @moduledoc "Sign & replay a Linear-style webhook to a target app, with delivery history."
  use LinearSimWeb, :live_view

  alias LinearSim.{Linear, Webhooks}

  @default_payload """
  {
    "action": "update",
    "data": {
      "id": "issue_eng_1",
      "identifier": "ENG-1",
      "title": "Build Linear simulator"
    }
  }\
  """

  @event_types ~w(IssueCreated IssueUpdated CommentCreated)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Webhooks")
     |> assign(:form, %{
       "target_url" => "http://localhost:4001/webhooks/linear",
       "secret" => "",
       "event_type" => "IssueUpdated",
       "payload" => @default_payload
     })
     |> assign(:note, nil)
     |> assign_shell(:webhooks)
     |> assign_data()}
  end

  @impl true
  def handle_event("deliver", params, socket) do
    %{"target_url" => target_url, "secret" => secret, "event_type" => type, "payload" => payload} =
      params

    note =
      case Jason.decode(payload) do
        {:ok, data} when is_map(data) ->
          event = Map.put(data, "type", type)

          case Webhooks.replay(target_url, secret, event) do
            {:ok, d} -> "Delivered: HTTP #{d.response_status}"
            {:error, d} -> "Delivery failed: #{d.error_reason}"
          end

        _ ->
          "Invalid JSON payload."
      end

    {:noreply, socket |> assign(:form, params) |> assign(:note, note) |> assign_data()}
  end

  @impl true
  def handle_info(:sim_changed, socket), do: {:noreply, assign_data(socket)}

  defp assign_data(socket), do: assign(socket, :deliveries, Linear.list_webhook_deliveries())

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :event_types, @event_types)

    ~H"""
    <.shell active={@active} scenario={@scenario} mode={@mode} capturing={@capturing} unsupported_count={@unsupported_count} show_unsupported={@show_unsupported} unsupported_entries={@unsupported_entries}>
      <h2 class="text-xl font-bold mb-4">Webhooks</h2>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div class="bg-surface-container-low border border-outline-variant rounded-lg p-4">
          <h3 class="text-[11px] font-semibold uppercase tracking-wide text-on-surface mb-4">Replay webhook</h3>
          <form id="webhook-replay" phx-submit="deliver" class="space-y-4">
            <div>
              <label class="block text-[13px] text-on-surface-variant mb-2">Target URL</label>
              <input type="text" name="target_url" value={@form["target_url"]}
                class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-2 font-mono text-xs outline-none focus:border-primary" />
            </div>
            <div>
              <label class="block text-[13px] text-on-surface-variant mb-2">Secret</label>
              <input type="password" name="secret" value={@form["secret"]} placeholder="webhook signing secret"
                class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-2 font-mono text-xs outline-none focus:border-primary" />
            </div>
            <div>
              <label class="block text-[13px] text-on-surface-variant mb-2">Event type</label>
              <select name="event_type" class="w-full bg-surface-container-lowest border border-outline-variant rounded px-3 py-2 text-[13px] outline-none focus:border-primary">
                <option :for={t <- @event_types} value={t} selected={@form["event_type"] == t}>{t}</option>
              </select>
            </div>
            <div>
              <label class="block text-[13px] text-on-surface-variant mb-2">Payload (JSON)</label>
              <textarea name="payload" spellcheck="false" rows="9"
                class="w-full bg-surface-container-lowest border border-outline-variant rounded p-3 font-mono text-xs outline-none focus:border-primary">{@form["payload"]}</textarea>
            </div>
            <button type="submit" class="w-full py-2 bg-primary text-on-primary font-bold rounded hover:brightness-110 transition flex items-center justify-center gap-2">
              <span class="material-symbols-outlined text-base">send</span> Sign &amp; deliver
            </button>
            <p :if={@note} class="text-[13px] font-mono text-primary">{@note}</p>
          </form>
        </div>

        <div class="bg-surface-container-low border border-outline-variant rounded-lg overflow-hidden flex flex-col">
          <h3 class="text-[11px] font-semibold uppercase tracking-wide text-on-surface p-4">Delivery history</h3>
          <div class="flex-1 overflow-y-auto">
            <p :if={@deliveries == []} class="px-4 py-8 text-center text-on-surface-variant text-[13px]">No deliveries yet.</p>
            <table :if={@deliveries != []} class="w-full text-left">
              <thead class="sticky top-0 bg-surface-container-high">
                <tr class="border-b border-outline-variant">
                  <th class="px-4 py-2 text-[10px] font-semibold uppercase tracking-wide text-on-surface-variant">Time</th>
                  <th class="px-4 py-2 text-[10px] font-semibold uppercase tracking-wide text-on-surface-variant">Event</th>
                  <th class="px-4 py-2 text-[10px] font-semibold uppercase tracking-wide text-on-surface-variant">Target</th>
                  <th class="px-4 py-2 text-[10px] font-semibold uppercase tracking-wide text-on-surface-variant">Status</th>
                  <th class="px-4 py-2 text-[10px] font-semibold uppercase tracking-wide text-on-surface-variant">HTTP</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-outline-variant">
                <tr :for={d <- @deliveries} class="hover:bg-surface-variant/20">
                  <td class="px-4 py-3 font-mono text-[11px] text-on-surface-variant">{format_time(d.inserted_at)}</td>
                  <td class="px-4 py-3 text-[13px]">{d.event_type}</td>
                  <td class="px-4 py-3 font-mono text-[11px] text-on-surface-variant">{host(d.target_url)}</td>
                  <td class="px-4 py-3">
                    <span class={[
                      "px-2 py-0.5 text-[10px] font-bold rounded uppercase",
                      d.status == "delivered" && "bg-emerald-500/10 text-emerald-400" || "bg-red-500/10 text-red-400"
                    ]}>{d.status}</span>
                  </td>
                  <td class="px-4 py-3 font-mono text-[13px] text-on-surface-variant">{d.response_status || "—"}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </.shell>
    """
  end

  defp format_time(nil), do: "-"
  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")

  defp host(url) do
    case URI.parse(url) do
      %URI{host: nil} -> url
      %URI{host: h, port: p} -> "#{h}:#{p}"
    end
  end
end
