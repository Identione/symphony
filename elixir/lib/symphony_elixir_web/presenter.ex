defmodule SymphonyElixirWeb.Presenter do
  @moduledoc """
  Shared projections for the observability API and dashboard.
  """

  alias SymphonyElixir.{Config, Orchestrator, StatusDashboard}
  alias SymphonyElixirWeb.HeroTint

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
      last_event: entry.last_codex_event,
      last_message: summarize_message(entry.last_codex_message),
      started_at: iso8601(entry.started_at),
      last_event_at: iso8601(entry.last_codex_timestamp),
      tokens: tokens_payload(entry)
    }
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

  defp edge_from_blocker(%{id: source_id}, target_id, known_ids) when is_binary(source_id) do
    if MapSet.member?(known_ids, source_id) do
      [%{source: source_id, target: target_id}]
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
      symphony_status_label: symphony_status_label(status)
    }
  end

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
