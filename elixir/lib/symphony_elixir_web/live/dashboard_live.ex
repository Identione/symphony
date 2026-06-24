defmodule SymphonyElixirWeb.DashboardLive do
  @moduledoc """
  Live observability dashboard for Symphony.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:payload, load_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:refresh_notice, nil)

    if connected?(socket) do
      :ok = ObservabilityPubSub.subscribe()
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("force_poll", _params, socket) do
    notice =
      case Presenter.refresh_payload(orchestrator()) do
        {:ok, %{coalesced: true}} ->
          "Poll already pending — request coalesced."

        {:ok, %{requested_at: requested_at}} ->
          "Poll queued at #{requested_at}. If a rate-limit window is active it runs once that clears."

        {:error, :unavailable} ->
          "Orchestrator unavailable — poll not queued."
      end

    {:noreply,
     socket
     |> assign(:refresh_notice, notice)
     |> assign(:payload, load_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card" style={@payload[:hero_tint]}>
        <div class="hero-grid">
          <div>
            <p class="eyebrow">
              Symphony Observability
            </p>
            <h1 class="hero-title">
              Operations Dashboard
            </h1>
            <%= if @payload[:linear_project] do %>
              <p class="hero-meta">
                Linear project: <span class="hero-meta-value"><%= @payload.linear_project %></span>
              </p>
            <% end %>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              Live
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              Offline
            </span>
            <button type="button" class="subtle-button" phx-click="force_poll">
              Force poll
            </button>
            <%= if @refresh_notice do %>
              <span class="hero-meta refresh-notice"><%= @refresh_notice %></span>
            <% end %>
          </div>
        </div>
      </header>

      <%= if @payload[:error] do %>
        <section class="error-card">
          <h2 class="error-title">
            Snapshot unavailable
          </h2>
          <p class="error-copy">
            <strong><%= @payload.error.code %>:</strong> <%= @payload.error.message %>
          </p>
        </section>
      <% else %>
        <section class="metric-grid">
          <article class="metric-card">
            <p class="metric-label">Running</p>
            <p class="metric-value numeric"><%= @payload.counts.running %></p>
            <p class="metric-detail">Active issue sessions in the current runtime.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Retrying</p>
            <p class="metric-value numeric"><%= @payload.counts.retrying %></p>
            <p class="metric-detail">Issues waiting for the next retry window.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Blocked</p>
            <p class="metric-value numeric"><%= @payload.counts.blocked %></p>
            <p class="metric-detail">Issues halted for operator input, approval, or a non-retryable failure.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Waiting on blockers</p>
            <p class="metric-value numeric"><%= @payload.counts.dependency_blocked %></p>
            <p class="metric-detail">Issues paused while a blocking issue is still open.</p>
          </article>

          <article class="metric-card">
            <p class="metric-label">Total tokens</p>
            <p class="metric-value numeric"><%= format_int(active_totals(@payload).total_tokens) %></p>
            <p class="metric-detail numeric">
              In <%= format_int(active_totals(@payload).input_tokens) %> / Out <%= format_int(active_totals(@payload).output_tokens) %>
            </p>
            <%= if @payload[:agent_kind] == "claude" do %>
              <p class="metric-detail numeric">
                Cache: created <%= format_int(@payload.claude_totals.cache_creation_input_tokens) %> · read <%= format_int(@payload.claude_totals.cache_read_input_tokens) %>
              </p>
            <% end %>
          </article>

          <article class="metric-card">
            <p class="metric-label">Runtime</p>
            <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@payload, @now)) %></p>
            <p class="metric-detail">Total agent runtime across completed and active sessions.</p>
          </article>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Provider quotas</h2>
              <p class="section-copy">Latest upstream quota snapshots, when available.</p>
            </div>
          </div>

          <% quota_cards = Presenter.provider_quota_cards(Map.get(@payload, :provider_quotas, %{})) %>
          <%= if quota_cards == [] do %>
            <p class="empty-state">No quota snapshots yet.</p>
          <% else %>
            <div class="quota-cards">
              <article :for={card <- quota_cards} class="quota-card">
                <div class="quota-provider-head">
                  <span class="quota-provider"><%= card.provider %></span>
                  <span class="quota-source"><%= card.source %></span>
                  <%= if card.stale do %>
                    <span class="status-badge quota-stale">Stale</span>
                  <% end %>
                </div>

                <%= if card.error do %>
                  <div class={"quota-error quota-error-#{card.error.level}"}>
                    <p class="quota-error-message">
                      <strong><%= card.error.message %></strong>
                      <%= if card.error.since do %>
                        <span class="quota-error-meta">· failing for <%= card.error.since %></span>
                      <% end %>
                    </p>
                    <%= if card.error.showing_last_known and card.fetched_ago do %>
                      <p class="quota-error-meta">Showing last-known usage from <%= card.fetched_ago %>.</p>
                    <% end %>
                    <%= if card.error.detail do %>
                      <p class="quota-error-meta"><%= card.error.code %>: <%= card.error.detail %></p>
                    <% end %>
                  </div>
                <% end %>

                <%= if card.buckets == [] do %>
                  <p class="empty-state">No usage buckets reported.</p>
                <% else %>
                  <div class="quota-row" :for={bucket <- card.buckets}>
                    <span class="quota-label"><%= bucket.label %></span>
                    <div class="quota-bar" title={"#{bucket.name}"}>
                      <div class={"quota-bar-fill quota-#{bucket.level}"} style={"width: #{bucket.width}%"}></div>
                      <%= if is_number(card.threshold) do %>
                        <div class="quota-bar-threshold" style={"left: #{card.threshold}%"} title={"pause at #{card.threshold}%"}></div>
                      <% end %>
                    </div>
                    <span class="quota-pct numeric">
                      <%= if is_number(bucket.used_percent), do: "#{bucket.used_percent}%", else: "n/a" %>
                    </span>
                    <span class="quota-resets"><%= bucket.resets_in || "—" %></span>
                  </div>
                <% end %>
              </article>
            </div>
          <% end %>

          <details class="quota-raw">
            <summary>Raw snapshot</summary>
            <pre class="code-panel"><%= pretty_value(Map.get(@payload, :provider_quotas, %{})) %></pre>
          </details>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Agent sessions</h2>
              <p class="section-copy">
                Active, retrying, and blocked issue sessions. Retrying entries re-run automatically; blocked entries wait for you to change their Linear state.
              </p>
            </div>
          </div>

          <div class="table-wrap">
            <table class="data-table data-table-running">
              <colgroup>
                <col style="width: 12rem;" />
                <col style="width: 11rem;" />
                <col style="width: 9rem;" />
                <col style="width: 10rem;" />
                <col />
              </colgroup>
              <thead>
                <tr>
                  <th>Issue</th>
                  <th>State</th>
                  <th>Time</th>
                  <th>Tokens</th>
                  <th>Description</th>
                </tr>
              </thead>
              <tbody>
                <%= if @payload.sessions == [] do %>
                  <tr>
                    <td colspan="5" class="empty-state">No sessions.</td>
                  </tr>
                <% else %>
                  <tr :for={entry <- @payload.sessions}>
                    <td>
                      <div class="issue-stack">
                        <.issue_identifier identifier={entry.issue_identifier} url={entry.issue_url} />
                        <a class="issue-link" href={"/api/v1/#{entry.issue_identifier}"}>JSON details</a>
                        <%= if entry[:session_id] do %>
                          <button
                            type="button"
                            class="subtle-button"
                            data-label="Copy ID"
                            data-copy={entry.session_id}
                            onclick="navigator.clipboard.writeText(this.dataset.copy); this.textContent = 'Copied'; clearTimeout(this._copyTimer); this._copyTimer = setTimeout(() => { this.textContent = this.dataset.label }, 1200);"
                          >
                            Copy ID
                          </button>
                        <% end %>
                      </div>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class={session_status_class(entry.status)}>
                          <%= session_status_label(entry.status) %>
                        </span>
                        <%= if session_state_sublabel(entry) do %>
                          <span class="muted event-meta"><%= session_state_sublabel(entry) %></span>
                        <% end %>
                      </div>
                    </td>
                    <td class="numeric"><%= session_time(entry, @now) %></td>
                    <td>
                      <%= if entry[:tokens] do %>
                        <div class="token-stack numeric">
                          <span>Total: <%= format_int(entry.tokens.total_tokens) %></span>
                          <span class="muted">In <%= format_int(entry.tokens.input_tokens) %> / Out <%= format_int(entry.tokens.output_tokens) %></span>
                          <%= if entry[:agent_kind] == "claude" do %>
                            <span class="muted">Cache: created <%= format_int(entry.tokens.cache_creation_input_tokens) %> · read <%= format_int(entry.tokens.cache_read_input_tokens) %></span>
                          <% end %>
                        </div>
                      <% else %>
                        <span class="muted">n/a</span>
                      <% end %>
                    </td>
                    <td>
                      <div class="detail-stack">
                        <span class="event-text" title={session_description(entry)}><%= session_description(entry) %></span>
                        <%= if entry[:last_event] || entry[:last_event_at] do %>
                          <span class="muted event-meta">
                            <%= entry[:last_event] || "n/a" %>
                            <%= if entry[:last_event_at] do %>
                              · <span class="mono numeric"><%= entry.last_event_at %></span>
                            <% end %>
                          </span>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Dependency graph</h2>
              <p class="section-copy">Blocking relationships across active issues and their transitive blockers.</p>
            </div>
          </div>

          <%= if @payload.dependency_graph.nodes == [] do %>
            <p class="empty-state">No dependency relationships found.</p>
          <% else %>
            <div
              id="dependency-graph"
              phx-hook="DependencyGraph"
              data-graph={Jason.encode!(@payload.dependency_graph)}
            >
              <div id="dependency-graph-canvas" phx-update="ignore" class="graph-canvas"></div>
            </div>
          <% end %>
        </section>
      <% end %>
    </section>
    """
  end

  defp load_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

  attr(:identifier, :string, required: true)
  attr(:url, :string, default: nil)

  defp issue_identifier(assigns) do
    assigns = assign(assigns, :href, external_issue_url(assigns.url))

    ~H"""
    <%= if @href do %>
      <a
        class="issue-id issue-id-link"
        href={@href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={"Open #{@identifier} in the issue tracker"}
      ><%= @identifier %></a>
    <% else %>
      <span class="issue-id"><%= @identifier %></span>
    <% end %>
    """
  end

  defp external_issue_url(url) when is_binary(url) do
    url = String.trim(url)

    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        url

      _ ->
        nil
    end
  end

  defp external_issue_url(_url), do: nil

  defp completed_runtime_seconds(payload) do
    active_totals(payload).seconds_running || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(payload.running, 0, fn entry, total ->
        total + runtime_seconds_from_started_at(entry.started_at, now)
      end)
  end

  # The Total tokens / Runtime metrics show the active adapter's totals so
  # that switching `agent.kind` doesn't strand counters from the other path.
  defp active_totals(%{agent_kind: "claude"} = payload), do: payload.claude_totals
  defp active_totals(payload), do: payload.codex_totals

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_number(seconds) do
    whole_seconds = max(trunc(seconds), 0)
    mins = div(whole_seconds, 60)
    secs = rem(whole_seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp runtime_seconds_from_started_at(%DateTime{} = started_at, %DateTime{} = now) do
    DateTime.diff(now, started_at, :second)
  end

  defp runtime_seconds_from_started_at(started_at, %DateTime{} = now) when is_binary(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, parsed, _offset} -> runtime_seconds_from_started_at(parsed, now)
      _ -> 0
    end
  end

  defp runtime_seconds_from_started_at(_started_at, _now), do: 0

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/.{3}(?=.)/, "\\0,")
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp session_status_label(:running), do: "Running"
  defp session_status_label(:retrying), do: "Retrying"
  defp session_status_label(:blocked), do: "Blocked"
  defp session_status_label(_status), do: "Session"

  defp session_status_class(:running), do: "state-badge state-badge-active"
  defp session_status_class(:retrying), do: "state-badge state-badge-warning"
  defp session_status_class(:blocked), do: "state-badge state-badge-danger"
  defp session_status_class(_status), do: "state-badge"

  # Secondary, muted line under the status badge: the Linear workflow state for
  # running/blocked rows, the retry attempt number for retrying rows.
  defp session_state_sublabel(%{status: :retrying, attempt: attempt}) when is_integer(attempt),
    do: "attempt #{attempt}"

  defp session_state_sublabel(%{status: status, state: state})
       when status in [:running, :blocked] and is_binary(state) and state != "",
       do: state

  defp session_state_sublabel(_entry), do: nil

  # The Time column is status-dependent: live runtime + turns while running, a
  # live countdown to the next retry while retrying, and elapsed-since while
  # blocked. All re-render on the 1s `:runtime_tick`.
  defp session_time(%{status: :running} = entry, now),
    do: format_runtime_and_turns(entry[:started_at], entry[:turn_count], now)

  defp session_time(%{status: :retrying, due_at: due_at}, now), do: format_due_in(due_at, now)

  defp session_time(%{status: :blocked, blocked_at: blocked_at}, now),
    do: format_blocked_since(blocked_at, now)

  defp session_time(_entry, _now), do: "n/a"

  defp format_due_in(due_at, now) when is_binary(due_at) do
    case DateTime.from_iso8601(due_at) do
      {:ok, parsed, _offset} ->
        case DateTime.diff(parsed, now, :second) do
          seconds when seconds > 0 -> "next try in #{format_runtime_seconds(seconds)}"
          _ -> "due now"
        end

      _ ->
        "n/a"
    end
  end

  defp format_due_in(_due_at, _now), do: "n/a"

  defp format_blocked_since(blocked_at, now) when is_binary(blocked_at) do
    case DateTime.from_iso8601(blocked_at) do
      {:ok, parsed, _offset} -> "blocked #{format_runtime_seconds(DateTime.diff(now, parsed, :second))} ago"
      _ -> "blocked"
    end
  end

  defp format_blocked_since(_blocked_at, _now), do: "blocked"

  # Description prefers the last agent message (running), then the block/retry
  # error reason, then the raw last event.
  defp session_description(entry) do
    entry[:last_message] || entry[:error] || to_string(entry[:last_event] || "n/a")
  end

  defp schedule_runtime_tick do
    Process.send_after(self(), :runtime_tick, @runtime_tick_ms)
  end

  defp pretty_value(nil), do: "n/a"
  defp pretty_value(value), do: inspect(value, pretty: true, limit: :infinity)
end
