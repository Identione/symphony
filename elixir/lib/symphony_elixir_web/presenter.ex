defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, ProviderQuota, StatusDashboard}
  alias SymphonyElixirWeb.HeroTint

  @default_dispatch_pause_percent 95.0

  @empty_claude_totals %{
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    cache_creation_input_tokens: 0,
    cache_read_input_tokens: 0,
    seconds_running: 0
  }

  @spec state_payload(GenServer.name(), timeout()) :: map()
  def state_payload(orchestrator, snapshot_timeout_ms) do
    generated_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        project = linear_project()

        dependency_blocked = Map.get(snapshot, :dependency_blocked, [])
        dependency_graph_nodes = Map.get(snapshot, :dependency_graph, [])

        %{
          generated_at: generated_at,
          agent_kind: active_agent_kind(),
          linear_project: project,
          hero_tint: HeroTint.inline_style(project),
          counts: %{
            running: length(snapshot.running),
            retrying: length(snapshot.retrying),
            blocked: length(Map.get(snapshot, :blocked, [])),
            dependency_blocked: length(dependency_blocked)
          },
          running: Enum.map(snapshot.running, &running_entry_payload/1),
          retrying: Enum.map(snapshot.retrying, &retry_entry_payload/1),
          blocked: Enum.map(Map.get(snapshot, :blocked, []), &blocked_entry_payload/1),
          sessions: session_entries(snapshot),
          dependency_blocked: Enum.map(dependency_blocked, &dependency_blocked_entry_payload/1),
          dependency_graph: dependency_graph_payload(dependency_graph_nodes),
          codex_totals: snapshot.codex_totals,
          claude_totals: Map.get(snapshot, :claude_totals) || @empty_claude_totals,
          provider_quotas: Map.get(snapshot, :provider_quotas) || %{},
          rate_limits: snapshot.rate_limits
        }

      :timeout ->
        %{generated_at: generated_at, error: %{code: "snapshot_timeout", message: "Snapshot timed out"}}

      :unavailable ->
        %{generated_at: generated_at, error: %{code: "snapshot_unavailable", message: "Snapshot unavailable"}}
    end
  end

  @spec issue_payload(String.t(), GenServer.name(), timeout()) :: {:ok, map()} | {:error, :issue_not_found}
  def issue_payload(issue_identifier, orchestrator, snapshot_timeout_ms) when is_binary(issue_identifier) do
    case Orchestrator.snapshot(orchestrator, snapshot_timeout_ms) do
      %{} = snapshot ->
        running = Enum.find(snapshot.running, &(&1.identifier == issue_identifier))
        retry = Enum.find(snapshot.retrying, &(&1.identifier == issue_identifier))
        blocked = Enum.find(Map.get(snapshot, :blocked, []), &(&1.identifier == issue_identifier))

        if is_nil(running) and is_nil(retry) and is_nil(blocked) do
          {:error, :issue_not_found}
        else
          {:ok, issue_payload_body(issue_identifier, running, retry, blocked)}
        end

      _ ->
        {:error, :issue_not_found}
    end
  end

  @spec refresh_payload(GenServer.name()) :: {:ok, map()} | {:error, :unavailable}
  def refresh_payload(orchestrator) do
    case Orchestrator.request_refresh(orchestrator) do
      :unavailable ->
        {:error, :unavailable}

      payload ->
        {:ok, Map.update!(payload, :requested_at, &DateTime.to_iso8601/1)}
    end
  end

  @doc """
  Projects the raw `provider_quotas` map (`%{codex: snapshot | nil, claude: snapshot | nil}`)
  into a render-ready list of provider cards for the dashboard.

  Each card carries a sorted list of buckets with the usage percent already rounded, a
  threshold-relative band (`:ok | :warn | :danger`), a stale flag, and a relative reset time.
  Providers without a snapshot are omitted; an empty list means "no snapshots yet".
  """
  @spec provider_quota_cards(map() | nil) :: [map()]
  def provider_quota_cards(provider_quotas) when is_map(provider_quotas) do
    now_ms = System.monotonic_time(:millisecond)
    now = DateTime.utc_now()

    [:codex, :claude]
    |> Enum.flat_map(fn provider ->
      case Map.get(provider_quotas, provider) do
        %{} = snapshot -> [provider_quota_card(provider, snapshot, now_ms, now)]
        _ -> []
      end
    end)
  end

  def provider_quota_cards(_provider_quotas), do: []

  defp provider_quota_card(provider, snapshot, now_ms, now) do
    threshold = provider_threshold(provider)

    %{
      provider: provider,
      source: Map.get(snapshot, :source),
      fetched_at: Map.get(snapshot, :fetched_at),
      stale: ProviderQuota.stale?(snapshot, now_ms),
      error: Map.get(snapshot, :error),
      threshold: threshold,
      buckets: quota_buckets(Map.get(snapshot, :buckets, %{}), threshold, now)
    }
  end

  defp quota_buckets(buckets, threshold, now) when is_map(buckets) do
    buckets
    |> Enum.map(fn {name, bucket} -> quota_bucket(to_string(name), bucket, threshold, now) end)
    |> Enum.sort_by(& &1.name)
  end

  defp quota_buckets(_buckets, _threshold, _now), do: []

  defp quota_bucket(name, bucket, threshold, now) do
    used = round_percent(Map.get(bucket, :used_percent))
    resets_at = Map.get(bucket, :resets_at)

    %{
      name: name,
      label: bucket_label(name),
      used_percent: used,
      width: clamp_percent(used),
      level: quota_level(used, threshold),
      over_threshold: is_number(used) and used >= threshold,
      resets_at: resets_at,
      resets_in: relative_reset(resets_at, now)
    }
  end

  defp round_percent(value) when is_number(value), do: Float.round(value / 1, 1)
  defp round_percent(_value), do: nil

  defp clamp_percent(value) when is_number(value), do: value |> max(0) |> min(100)
  defp clamp_percent(_value), do: 0

  defp quota_level(used, threshold) when is_number(used) and is_number(threshold) do
    cond do
      used >= threshold -> :danger
      used >= threshold * 0.8 -> :warn
      true -> :ok
    end
  end

  defp quota_level(_used, _threshold), do: :ok

  defp bucket_label("five_hour"), do: "5h"
  defp bucket_label("seven_day"), do: "Weekly"
  defp bucket_label("seven_day_opus"), do: "Weekly · Opus"
  defp bucket_label("seven_day_sonnet"), do: "Weekly · Sonnet"
  defp bucket_label("seven_day_design"), do: "Weekly · Design"
  defp bucket_label("seven_day_cowork"), do: "Weekly · Cowork"
  defp bucket_label("seven_day_oauth_apps"), do: "Weekly · OAuth apps"

  defp bucket_label(name) do
    cond do
      String.ends_with?(name, ".primary") -> "Primary"
      String.ends_with?(name, ".secondary") -> "Secondary"
      true -> name
    end
  end

  defp relative_reset(resets_at, now) when is_binary(resets_at) do
    case DateTime.from_iso8601(resets_at) do
      {:ok, dt, _offset} ->
        case DateTime.diff(dt, now, :second) do
          seconds when seconds > 0 -> "in " <> humanize_duration(seconds)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp relative_reset(_resets_at, _now), do: nil

  defp humanize_duration(seconds) when is_integer(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3_600)
    minutes = div(rem(seconds, 3_600), 60)

    cond do
      days > 0 -> "#{days}d #{hours}h"
      hours > 0 -> "#{hours}h #{minutes}m"
      minutes > 0 -> "#{minutes}m"
      true -> "<1m"
    end
  end

  defp provider_threshold(provider) do
    case provider_quota_config(Config.settings!(), provider) do
      %{dispatch_pause_percent: value} when is_number(value) -> value
      _ -> @default_dispatch_pause_percent
    end
  end

  defp provider_quota_config(%{codex: %{quota: %{} = quota}}, :codex), do: quota
  defp provider_quota_config(%{agent: %{claude: %{quota: %{} = quota}}}, :claude), do: quota
  defp provider_quota_config(_config, _provider), do: nil

  defp issue_payload_body(issue_identifier, running, retry, blocked) do
    %{
      issue_identifier: issue_identifier,
      issue_id: issue_id_from_entries(running, retry, blocked),
      status: issue_status(running, retry, blocked),
      workspace: %{
        path: workspace_path(issue_identifier, running, retry, blocked),
        host: workspace_host(running, retry, blocked)
      },
      attempts: %{
        restart_count: restart_count(retry),
        current_retry_attempt: retry_attempt(retry)
      },
      running: running && running_issue_payload(running),
      retry: retry && retry_issue_payload(retry),
      blocked: blocked && blocked_issue_payload(blocked),
      logs: %{
        codex_session_logs: []
      },
      recent_events: recent_events_payload(running || blocked),
      last_error: (blocked && blocked.error) || (retry && retry.error),
      tracked: %{}
    }
  end

  defp issue_id_from_entries(running, retry, blocked),
    do: (running && running.issue_id) || (retry && retry.issue_id) || (blocked && blocked.issue_id)

  defp restart_count(retry), do: max(retry_attempt(retry) - 1, 0)
  defp retry_attempt(nil), do: 0
  defp retry_attempt(retry), do: retry.attempt || 0

  defp issue_status(running, _retry, _blocked) when not is_nil(running), do: "running"
  defp issue_status(nil, retry, _blocked) when not is_nil(retry), do: "retrying"
  defp issue_status(nil, nil, _blocked), do: "blocked"

  defp running_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      agent_kind: agent_kind_string(entry),
      turn_count: Map.get(entry, :turn_count, 0),
      progress: progress_payload(entry),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: tokens_payload(entry)
    }
  end

  # IDE-211 Layer 1 progress assessment (status + the independent
  # `at_risk_no_commits` flag). The orchestrator snapshot always carries an
  # assessment (neutral default before the first turn); JSON-friendly map only.
  defp progress_payload(entry) do
    case Map.get(entry, :progress_assessment) do
      %{status: status, at_risk_no_commits: at_risk} ->
        %{status: status, at_risk_no_commits: at_risk}

      _ ->
        %{status: :progressing, at_risk_no_commits: false}
    end
  end

  defp retry_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      attempt: entry.attempt,
      due_at: due_at_iso8601(entry.due_in_ms),
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path)
    }
  end

  defp blocked_entry_payload(entry) do
    %{
      issue_id: entry.issue_id,
      issue_identifier: entry.identifier,
      state: entry.state,
      error: entry.error,
      worker_host: Map.get(entry, :worker_host),
      workspace_path: Map.get(entry, :workspace_path),
      session_id: entry.session_id,
      blocked_at: iso8601(entry.blocked_at),
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      last_event_at: iso8601(entry.last_codex_timestamp)
    }
  end

  # Unified session view for the dashboard's single "Sessions" table. Each of
  # the three orchestrator tables (running / retrying / blocked) is a distinct
  # Symphony status for one issue, so we tag the existing per-status payloads
  # with `:status` and concatenate them in priority order (running first). The
  # template reads fields defensively (`entry[:key]`), so absent keys — e.g.
  # `:tokens` on a retry row — simply render as "n/a". The original
  # `running`/`retrying`/`blocked` keys are kept untouched for the JSON API.
  defp session_entries(snapshot) do
    Enum.map(snapshot.running, &Map.put(running_entry_payload(&1), :status, :running)) ++
      Enum.map(snapshot.retrying, &Map.put(retry_entry_payload(&1), :status, :retrying)) ++
      Enum.map(Map.get(snapshot, :blocked, []), &Map.put(blocked_entry_payload(&1), :status, :blocked))
  end

  defp dependency_blocked_entry_payload(entry) do
    %{
      issue_id: Map.get(entry, :issue_id),
      issue_identifier: Map.get(entry, :identifier),
      title: Map.get(entry, :title),
      state: Map.get(entry, :state),
      blocked_by: Enum.map(Map.get(entry, :blocked_by, []), &blocker_ref_payload/1),
      observed_at: iso8601(Map.get(entry, :observed_at))
    }
  end

  defp blocker_ref_payload(%{} = ref) do
    %{
      issue_id: Map.get(ref, :id),
      issue_identifier: Map.get(ref, :identifier),
      state: Map.get(ref, :state)
    }
  end

  # Non-map blocker refs (e.g. a stray atom in a malformed Linear inverse
  # relation) still indicate an upstream block exists; surface them as nil-only
  # placeholders rather than crashing the snapshot serialization.
  defp blocker_ref_payload(_other) do
    %{issue_id: nil, issue_identifier: nil, state: nil}
  end

  defp dependency_graph_payload(nodes) when is_list(nodes) do
    node_payloads = Enum.map(nodes, &dependency_graph_node_payload/1)
    known_ids = MapSet.new(node_payloads, & &1.id)
    edges = Enum.flat_map(nodes, &edges_for_node(&1, known_ids))
    %{nodes: node_payloads, edges: edges}
  end

  defp dependency_graph_payload(_nodes), do: %{nodes: [], edges: []}

  defp edges_for_node(node, known_ids) do
    target_id = Map.get(node, :id) || Map.get(node, :issue_id)

    node
    |> Map.get(:blocked_by, [])
    |> Enum.flat_map(&edge_from_blocker(&1, target_id, known_ids))
  end

  defp edge_from_blocker(%{id: source_id} = blocker, target_id, known_ids)
       when is_binary(source_id) do
    if MapSet.member?(known_ids, source_id) do
      [%{source: source_id, target: target_id, kind: Map.get(blocker, :relation, "blocks")}]
    else
      []
    end
  end

  defp edge_from_blocker(_blocker, _target_id, _known_ids), do: []

  defp dependency_graph_node_payload(node) do
    priority = Map.get(node, :priority)
    status = Map.get(node, :symphony_status)

    %{
      id: Map.get(node, :id) || Map.get(node, :issue_id),
      issue_identifier: Map.get(node, :identifier),
      title: Map.get(node, :title),
      state: Map.get(node, :state),
      state_type: Map.get(node, :state_type),
      priority: priority,
      priority_label: priority_label(priority),
      url: Map.get(node, :url),
      placeholder: Map.get(node, :placeholder, false) == true,
      symphony_status: symphony_status_string(status),
      symphony_status_label: symphony_status_label(status),
      session_id: Map.get(node, :session_id),
      workspace_path: Map.get(node, :workspace_path),
      inactive_reason: Map.get(node, :inactive_reason),
      # Sub-issue containment + manageability. `kind` is "container" for an
      # umbrella/parent node and "issue" otherwise; `parent` is the container id
      # a sub-issue belongs to (nil for top-level nodes); `managed` is false for
      # sub-issues this instance would not pick up, with `requirements` listing
      # what must change. Containers also report aggregate sub-issue progress.
      kind: graph_node_kind(Map.get(node, :kind)),
      parent: Map.get(node, :parent),
      managed: Map.get(node, :managed, true) == true,
      requirements: Map.get(node, :requirements, []),
      child_total: Map.get(node, :child_total),
      child_done: Map.get(node, :child_done)
    }
  end

  defp graph_node_kind(:container), do: "container"
  defp graph_node_kind(_kind), do: "issue"

  defp priority_label(1), do: "Urgent"
  defp priority_label(2), do: "High"
  defp priority_label(3), do: "Medium"
  defp priority_label(4), do: "Low"
  defp priority_label(_priority), do: "No priority"

  defp symphony_status_string(:running), do: "running"
  defp symphony_status_string(:retrying), do: "retrying"
  defp symphony_status_string(:blocked), do: "blocked"
  defp symphony_status_string(:waiting_on_blockers), do: "waiting_on_blockers"
  defp symphony_status_string(_status), do: nil

  defp symphony_status_label(:running), do: "Running"
  defp symphony_status_label(:retrying), do: "Retrying"
  defp symphony_status_label(:blocked), do: "Blocked"
  defp symphony_status_label(:waiting_on_blockers), do: "Waiting on blockers"
  defp symphony_status_label(_status), do: nil

  defp running_issue_payload(running) do
    %{
      worker_host: Map.get(running, :worker_host),
      workspace_path: Map.get(running, :workspace_path),
      session_id: running.session_id,
      agent_kind: agent_kind_string(running),
      turn_count: Map.get(running, :turn_count, 0),
      state: running.state,
      started_at: iso8601(running.started_at),
      last_event: running.last_codex_event,
      last_message: summarize_message(running.last_codex_message),
      last_event_at: iso8601(running.last_codex_timestamp),
      tokens: tokens_payload(running)
    }
  end

  # Codex JSON shape stays as-is so existing consumers don't break. Claude
  # entries get the four Anthropic billing fields as siblings of `total_tokens`
  # — never folded in (`total_tokens = input + output`, codex parity).
  defp tokens_payload(entry) do
    case Map.get(entry, :agent_kind, :codex) do
      :claude ->
        %{
          input_tokens: Map.get(entry, :claude_input_tokens, 0),
          output_tokens: Map.get(entry, :claude_output_tokens, 0),
          total_tokens: Map.get(entry, :claude_total_tokens, 0),
          cache_creation_input_tokens: Map.get(entry, :claude_cache_creation_input_tokens, 0),
          cache_read_input_tokens: Map.get(entry, :claude_cache_read_input_tokens, 0)
        }

      _ ->
        %{
          input_tokens: Map.get(entry, :codex_input_tokens, 0),
          output_tokens: Map.get(entry, :codex_output_tokens, 0),
          total_tokens: Map.get(entry, :codex_total_tokens, 0)
        }
    end
  end

  defp agent_kind_string(entry) do
    case Map.get(entry, :agent_kind, :codex) do
      :claude -> "claude"
      _ -> "codex"
    end
  end

  defp active_agent_kind do
    case Config.adapter_module() do
      SymphonyElixir.Claude.AppServer -> "claude"
      _ -> "codex"
    end
  end

  defp linear_project do
    Config.settings!().tracker.project_slug
  end

  defp retry_issue_payload(retry) do
    %{
      attempt: retry.attempt,
      due_at: due_at_iso8601(retry.due_in_ms),
      error: retry.error,
      worker_host: Map.get(retry, :worker_host),
      workspace_path: Map.get(retry, :workspace_path)
    }
  end

  defp blocked_issue_payload(blocked) do
    %{
      worker_host: Map.get(blocked, :worker_host),
      workspace_path: Map.get(blocked, :workspace_path),
      session_id: blocked.session_id,
      state: blocked.state,
      error: blocked.error,
      blocked_at: iso8601(blocked.blocked_at),
      last_event: blocked.last_codex_event,
      last_message: summarize_message(blocked.last_codex_message),
      last_event_at: iso8601(blocked.last_codex_timestamp)
    }
  end

  defp workspace_path(issue_identifier, running, retry, blocked) do
    (running && Map.get(running, :workspace_path)) ||
      (retry && Map.get(retry, :workspace_path)) ||
      (blocked && Map.get(blocked, :workspace_path)) ||
      Path.join(Config.settings!().workspace.root, issue_identifier)
  end

  defp workspace_host(running, retry, blocked) do
    (running && Map.get(running, :worker_host)) ||
      (retry && Map.get(retry, :worker_host)) ||
      (blocked && Map.get(blocked, :worker_host))
  end

  defp recent_events_payload(nil), do: []

  defp recent_events_payload(entry) do
    [
      %{
        at: iso8601(entry.last_codex_timestamp),
        event: entry.last_codex_event,
        message: summarize_message(entry.last_codex_message)
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  defp summarize_message(nil), do: nil
  defp summarize_message(message), do: StatusDashboard.humanize_codex_message(message)

  defp due_at_iso8601(due_in_ms) when is_integer(due_in_ms) do
    DateTime.utc_now()
    |> DateTime.add(div(due_in_ms, 1_000), :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp due_at_iso8601(_due_in_ms), do: nil

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp iso8601(_datetime), do: nil
end
