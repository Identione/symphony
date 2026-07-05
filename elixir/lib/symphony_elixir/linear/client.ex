defmodule SymphonyElixir.Linear.Client do
  @moduledoc """
  Thin Linear GraphQL client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue, Linear.Pagination, Linear.RateLimit}

  @issue_page_size 50
  @max_error_body_log_bytes 1_000

  # Bound on how many sub-issues we pull per parent when building the dependency
  # graph's containers. Linear scores nested connections multiplicatively, so a
  # large family fetched via both `children` and `parent.children` must stay
  # well under the API complexity budget — keep this conservative.
  @child_page_size 50

  # Shared selection set for a sub-issue node. Carries exactly the fields the
  # orchestrator's manageability check needs (state, labels, assignee) plus the
  # display fields the dashboard renders, and nothing deeper (no nested
  # children/relations) so the query stays bounded.
  @issue_child_fields """
              id
              identifier
              title
              priority
              state {
                name
                type
              }
              url
              assignee {
                id
              }
              labels {
                nodes {
                  name
                }
              }
  """

  @query """
  query SymphonyLinearPoll($projectSlug: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!, $after: String) {
    issues(filter: {project: {slugId: {eq: $projectSlug}}, state: {name: {in: $stateNames}}}, first: $first, after: $after) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
          type
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        children(first: #{@child_page_size}) {
          nodes {
  #{@issue_child_fields}          }
        }
        parent {
          id
          identifier
          title
          url
          state {
            name
            type
          }
          children(first: #{@child_page_size}) {
            nodes {
  #{@issue_child_fields}            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
              attachments {
                nodes {
                  url
                }
              }
            }
          }
        }
        createdAt
        updatedAt
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
  """

  @query_by_ids """
  query SymphonyLinearIssuesById($ids: [ID!]!, $first: Int!, $relationFirst: Int!) {
    issues(filter: {id: {in: $ids}}, first: $first) {
      nodes {
        id
        identifier
        title
        description
        priority
        state {
          name
          type
        }
        branchName
        url
        assignee {
          id
        }
        labels {
          nodes {
            name
          }
        }
        children(first: #{@child_page_size}) {
          nodes {
  #{@issue_child_fields}          }
        }
        parent {
          id
          identifier
          title
          url
          state {
            name
            type
          }
          children(first: #{@child_page_size}) {
            nodes {
  #{@issue_child_fields}            }
          }
        }
        inverseRelations(first: $relationFirst) {
          nodes {
            type
            issue {
              id
              identifier
              state {
                name
              }
              attachments {
                nodes {
                  url
                }
              }
            }
          }
        }
        createdAt
        updatedAt
      }
    }
  }
  """

  @viewer_query """
  query SymphonyLinearViewer {
    viewer {
      id
    }
  }
  """

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker
    project_slug = tracker.project_slug

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_linear_api_token}

      is_nil(project_slug) ->
        {:error, :missing_linear_project_slug}

      true ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_by_states(project_slug, tracker.active_states, assignee_filter)
        end
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      project_slug = tracker.project_slug

      cond do
        is_nil(tracker.api_key) ->
          {:error, :missing_linear_api_token}

        is_nil(project_slug) ->
          {:error, :missing_linear_project_slug}

        true ->
          do_fetch_by_states(project_slug, normalized_states, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter() do
          do_fetch_issue_states(ids, assignee_filter)
        end
    end
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables \\ %{}, opts \\ [])
      when is_binary(query) and is_map(variables) and is_list(opts) do
    if RateLimit.allowed?() do
      do_graphql(query, variables, opts)
    else
      Logger.debug("Skipping Linear GraphQL request; rate-limit window active")
      {:error, :rate_limited}
    end
  end

  defp do_graphql(query, variables, opts) do
    payload = build_graphql_payload(query, variables, Keyword.get(opts, :operation_name))
    request_fun = Keyword.get(opts, :request_fun, &post_graphql_request/2)

    with {:ok, headers} <- graphql_headers(),
         {:ok, %{status: 200, body: body}} <- request_fun.(payload, headers) do
      case RateLimit.maybe_record_response(body) do
        :rate_limited -> {:error, :rate_limited}
        :ok -> {:ok, body}
      end
    else
      {:ok, response} ->
        body = Map.get(response, :body)

        case RateLimit.maybe_record_response(response.status, body) do
          :rate_limited ->
            {:error, :rate_limited}

          :ok ->
            Logger.error(
              "Linear GraphQL request failed status=#{response.status}" <>
                linear_error_context(payload, response)
            )

            # Carry the parsed body so callers (notably `Codex.DynamicTool`) can
            # surface Linear's GraphQL `errors[]` array to the agent for self-
            # correction. Body is whatever the HTTP layer parsed (map for JSON,
            # string for text, nil if unparseable).
            {:error, {:linear_api_status, response.status, body}}
        end

      {:error, reason} ->
        Logger.error("Linear GraphQL request failed: #{inspect(reason)}")
        {:error, {:linear_api_request, reason}}
    end
  end

  @doc false
  @spec normalize_issue_for_test(map()) :: Issue.t() | nil
  def normalize_issue_for_test(issue) when is_map(issue) do
    normalize_issue(issue, nil)
  end

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  @doc false
  @spec merge_issue_pages_for_test([[Issue.t()]]) :: [Issue.t()]
  def merge_issue_pages_for_test(issue_pages) when is_list(issue_pages) do
    issue_pages
    |> Enum.reduce([], &prepend_page_issues/2)
    |> finalize_paginated_issues()
  end

  @doc false
  @spec do_fetch_by_states_for_test(
          String.t(),
          [String.t()],
          map() | nil,
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, [Issue.t()]} | {:error, term()}
  def do_fetch_by_states_for_test(project_slug, state_names, assignee_filter, graphql_fun)
      when is_binary(project_slug) and is_list(state_names) and is_function(graphql_fun, 2) do
    do_fetch_by_states(project_slug, state_names, assignee_filter, graphql_fun)
  end

  @doc false
  @spec fetch_issue_states_by_ids_for_test([String.t()], (String.t(), map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids_for_test(issue_ids, graphql_fun)
      when is_list(issue_ids) and is_function(graphql_fun, 2) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        do_fetch_issue_states(ids, nil, graphql_fun)
    end
  end

  @doc false
  @spec resolve_assignee_filter_for_test(
          String.t(),
          (String.t(), map() -> {:ok, map()} | {:error, term()})
        ) :: {:ok, map() | nil} | {:error, term()}
  def resolve_assignee_filter_for_test(assignee, graphql_fun)
      when is_binary(assignee) and is_function(graphql_fun, 2) do
    build_assignee_filter(assignee, graphql_fun)
  end

  @doc false
  @spec reset_viewer_cache() :: :ok
  def reset_viewer_cache do
    :persistent_term.get()
    |> Enum.each(fn
      {{__MODULE__, :viewer, _hash} = key, _value} -> :persistent_term.erase(key)
      _other -> :ok
    end)

    :ok
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter) do
    do_fetch_by_states(project_slug, state_names, assignee_filter, &graphql/2)
  end

  defp do_fetch_by_states(project_slug, state_names, assignee_filter, graphql_fun)
       when is_function(graphql_fun, 2) do
    Pagination.paginate(fn after_cursor ->
      with {:ok, body} <-
             graphql_fun.(@query, %{
               projectSlug: project_slug,
               stateNames: state_names,
               first: @issue_page_size,
               relationFirst: @issue_page_size,
               after: after_cursor
             }) do
        decode_linear_page_response(body, assignee_filter)
      end
    end)
  end

  defp prepend_page_issues(issues, acc_issues) when is_list(issues) and is_list(acc_issues) do
    Enum.reverse(issues, acc_issues)
  end

  defp finalize_paginated_issues(acc_issues) when is_list(acc_issues), do: Enum.reverse(acc_issues)

  defp do_fetch_issue_states(ids, assignee_filter) do
    do_fetch_issue_states(ids, assignee_filter, &graphql/2)
  end

  defp do_fetch_issue_states(ids, assignee_filter, graphql_fun)
       when is_list(ids) and is_function(graphql_fun, 2) do
    issue_order_index = issue_order_index(ids)
    do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, [], issue_order_index)
  end

  defp do_fetch_issue_states_page([], _assignee_filter, _graphql_fun, acc_issues, issue_order_index) do
    acc_issues
    |> finalize_paginated_issues()
    |> sort_issues_by_requested_ids(issue_order_index)
    |> then(&{:ok, &1})
  end

  defp do_fetch_issue_states_page(ids, assignee_filter, graphql_fun, acc_issues, issue_order_index) do
    {batch_ids, rest_ids} = Enum.split(ids, @issue_page_size)

    case graphql_fun.(@query_by_ids, %{
           ids: batch_ids,
           first: length(batch_ids),
           relationFirst: @issue_page_size
         }) do
      {:ok, body} ->
        with {:ok, issues} <- decode_linear_response(body, assignee_filter) do
          updated_acc = prepend_page_issues(issues, acc_issues)
          do_fetch_issue_states_page(rest_ids, assignee_filter, graphql_fun, updated_acc, issue_order_index)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp issue_order_index(ids) when is_list(ids) do
    ids
    |> Enum.with_index()
    |> Map.new()
  end

  defp sort_issues_by_requested_ids(issues, issue_order_index)
       when is_list(issues) and is_map(issue_order_index) do
    fallback_index = map_size(issue_order_index)

    Enum.sort_by(issues, fn
      %Issue{id: issue_id} -> Map.get(issue_order_index, issue_id, fallback_index)
      _ -> fallback_index
    end)
  end

  defp build_graphql_payload(query, variables, operation_name) do
    %{
      "query" => query,
      "variables" => variables
    }
    |> maybe_put_operation_name(operation_name)
  end

  defp maybe_put_operation_name(payload, operation_name) when is_binary(operation_name) do
    trimmed = String.trim(operation_name)

    if trimmed == "" do
      payload
    else
      Map.put(payload, "operationName", trimmed)
    end
  end

  defp maybe_put_operation_name(payload, _operation_name), do: payload

  defp linear_error_context(payload, response) when is_map(payload) do
    operation_name =
      case Map.get(payload, "operationName") do
        name when is_binary(name) and name != "" -> " operation=#{name}"
        _ -> ""
      end

    body =
      response
      |> Map.get(:body)
      |> summarize_error_body()

    operation_name <> " body=" <> body
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end

  defp graphql_headers do
    case Config.settings!().tracker.api_key do
      nil ->
        {:error, :missing_linear_api_token}

      token ->
        {:ok,
         [
           {"Authorization", token},
           {"Content-Type", "application/json"}
         ]}
    end
  end

  defp post_graphql_request(payload, headers) do
    Req.post(Config.settings!().tracker.endpoint,
      headers: headers,
      json: payload,
      connect_options: [timeout: 30_000]
    )
  end

  defp decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
    issues =
      nodes
      |> Enum.map(&normalize_issue(&1, assignee_filter))
      |> Enum.reject(&is_nil(&1))

    {:ok, issues}
  end

  defp decode_linear_response(%{"errors" => errors}, _assignee_filter) do
    {:error, {:linear_graphql_errors, errors}}
  end

  defp decode_linear_response(_unknown, _assignee_filter) do
    {:error, :linear_unknown_payload}
  end

  defp decode_linear_page_response(
         %{
           "data" => %{
             "issues" => %{
               "nodes" => nodes,
               "pageInfo" => %{"hasNextPage" => has_next_page, "endCursor" => end_cursor}
             }
           }
         },
         assignee_filter
       ) do
    with {:ok, issues} <- decode_linear_response(%{"data" => %{"issues" => %{"nodes" => nodes}}}, assignee_filter) do
      {:ok, issues, %{has_next_page: has_next_page == true, end_cursor: end_cursor}}
    end
  end

  defp decode_linear_page_response(response, assignee_filter), do: decode_linear_response(response, assignee_filter)

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    assignee = issue["assignee"]

    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"],
      description: issue["description"],
      priority: parse_priority(issue["priority"]),
      state: get_in(issue, ["state", "name"]),
      state_type: get_in(issue, ["state", "type"]),
      branch_name: issue["branchName"],
      url: issue["url"],
      assignee_id: assignee_field(assignee, "id"),
      blocked_by: extract_blockers(issue),
      labels: extract_labels(issue),
      assigned_to_worker: assigned_to_worker?(assignee, assignee_filter),
      has_children: extract_has_children(issue),
      parent_id: get_in(issue, ["parent", "id"]),
      parent: extract_parent(issue, assignee_filter),
      children: extract_children(issue, assignee_filter),
      created_at: parse_datetime(issue["createdAt"]),
      updated_at: parse_datetime(issue["updatedAt"])
    }
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  defp assignee_field(%{} = assignee, field) when is_binary(field), do: assignee[field]
  defp assignee_field(_assignee, _field), do: nil

  defp assigned_to_worker?(_assignee, nil), do: true

  defp assigned_to_worker?(%{} = assignee, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    assignee
    |> assignee_id()
    |> then(fn
      nil -> false
      assignee_id -> MapSet.member?(match_values, assignee_id)
    end)
  end

  defp assigned_to_worker?(_assignee, _assignee_filter), do: false

  defp assignee_id(%{} = assignee), do: normalize_assignee_match_value(assignee["id"])

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    build_assignee_filter(assignee, &graphql/2)
  end

  defp build_assignee_filter(assignee, graphql_fun)
       when is_binary(assignee) and is_function(graphql_fun, 2) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      normalized ->
        # The "me" sentinel is matched case-insensitively — WORKFLOW.md
        # (`assignee: Me`) and env passthrough (`LINEAR_ASSIGNEE=ME`) can
        # both surface non-lowercase values. Anything else stays a
        # byte-exact literal match against the real Linear assignee id.
        if String.downcase(normalized) == "me" do
          resolve_viewer_assignee_filter(graphql_fun)
        else
          {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
        end
    end
  end

  defp resolve_viewer_assignee_filter(graphql_fun) when is_function(graphql_fun, 2) do
    cache_key = viewer_cache_key()

    case :persistent_term.get(cache_key, :not_cached) do
      :not_cached -> resolve_and_cache_viewer(graphql_fun, cache_key)
      viewer_id -> {:ok, viewer_assignee_filter(viewer_id)}
    end
  end

  defp resolve_and_cache_viewer(graphql_fun, cache_key) do
    case graphql_fun.(@viewer_query, %{}) do
      {:ok, %{"data" => %{"viewer" => viewer}}} when is_map(viewer) ->
        case assignee_id(viewer) do
          nil ->
            {:error, :missing_linear_viewer_identity}

          viewer_id ->
            # Only a successful resolution is cached — a transient error
            # must not poison future ticks with a permanent failure.
            :persistent_term.put(cache_key, viewer_id)
            {:ok, viewer_assignee_filter(viewer_id)}
        end

      {:ok, _body} ->
        {:error, :missing_linear_viewer_identity}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp viewer_assignee_filter(viewer_id) do
    %{configured_assignee: "me", match_values: MapSet.new([viewer_id])}
  end

  # Viewer identity is effectively immutable for a given API token, so caching
  # it in :persistent_term spares an extra Linear GraphQL call on every
  # `fetch_candidate_issues/0` / `fetch_issue_states_by_ids/1` tick. Keyed on a
  # hash of the token (never the raw secret) so switching Linear API keys
  # can't serve a stale viewer from a previous token's cache entry.
  defp viewer_cache_key do
    token = Config.settings!().tracker.api_key
    {__MODULE__, :viewer, :erlang.phash2(token)}
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp extract_labels(%{"labels" => %{"nodes" => labels}}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_), do: []

  defp extract_blockers(%{"inverseRelations" => %{"nodes" => inverse_relations}})
       when is_list(inverse_relations) do
    inverse_relations
    |> Enum.flat_map(fn
      %{"type" => relation_type, "issue" => blocker_issue}
      when is_binary(relation_type) and is_map(blocker_issue) ->
        normalized_relation = String.downcase(String.trim(relation_type))

        if normalized_relation == "blocks" do
          [
            %{
              id: blocker_issue["id"],
              identifier: blocker_issue["identifier"],
              state: get_in(blocker_issue, ["state", "name"]),
              pr_url: extract_pr_url(blocker_issue),
              relation: normalized_relation
            }
          ]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_), do: []

  # The blocker's GitHub PR URL, read from its Linear attachments. Linear links
  # the opened PR as an attachment, so we pick the first attachment whose URL
  # looks like a GitHub pull-request link; `nil` when none is present yet.
  defp extract_pr_url(%{"attachments" => %{"nodes" => nodes}}) when is_list(nodes) do
    nodes
    |> Enum.map(& &1["url"])
    |> Enum.find(&github_pr_url?/1)
  end

  defp extract_pr_url(_), do: nil

  defp github_pr_url?(url) when is_binary(url), do: Regex.match?(~r{github\.com/.+/pull/\d+}, url)
  defp github_pr_url?(_), do: false

  defp extract_has_children(%{"children" => %{"nodes" => nodes}}) when is_list(nodes), do: nodes != []
  defp extract_has_children(_), do: false

  # The parent issue (one level up) normalized into an `Issue`, carrying its own
  # `children` (this issue's siblings) so the orchestrator can build a container
  # node from any managed child without a second fetch. Bounded: the parent's
  # selection set does not nest a further `parent`, so recursion stops here.
  defp extract_parent(%{"parent" => parent}, assignee_filter) when is_map(parent) do
    normalize_issue(parent, assignee_filter)
  end

  defp extract_parent(_issue, _assignee_filter), do: nil

  # Sub-issues normalized into `Issue` structs with `parent_id` backfilled to the
  # owning issue. Children are selected with the full `@issue_child_fields` set;
  # entries lacking an `identifier` (e.g. a legacy `children(first: 1) { id }`
  # probe) are dropped so they never masquerade as real sub-issues.
  defp extract_children(%{"id" => parent_id, "children" => %{"nodes" => nodes}}, assignee_filter)
       when is_list(nodes) do
    nodes
    |> Enum.map(&normalize_child(&1, parent_id, assignee_filter))
    |> Enum.reject(&is_nil/1)
  end

  defp extract_children(_issue, _assignee_filter), do: []

  defp normalize_child(%{"identifier" => identifier} = child, parent_id, assignee_filter)
       when is_binary(identifier) do
    case normalize_issue(child, assignee_filter) do
      %Issue{} = normalized -> %{normalized | parent_id: parent_id}
      nil -> nil
    end
  end

  defp normalize_child(_child, _parent_id, _assignee_filter), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_priority(priority) when is_integer(priority), do: priority
  defp parse_priority(_priority), do: nil
end
