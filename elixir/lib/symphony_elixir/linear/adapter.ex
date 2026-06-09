defmodule SymphonyElixir.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.{Client, Pagination}

  @create_comment_mutation """
  mutation SymphonyCreateComment($issueId: String!, $body: String!) {
    commentCreate(input: {issueId: $issueId, body: $body}) {
      success
    }
  }
  """

  @update_state_mutation """
  mutation SymphonyUpdateIssueState($issueId: String!, $stateId: String!) {
    issueUpdate(id: $issueId, input: {stateId: $stateId}) {
      success
    }
  }
  """

  @state_lookup_query """
  query SymphonyResolveStateId($issueId: String!, $stateName: String!) {
    issue(id: $issueId) {
      team {
        states(filter: {name: {eq: $stateName}}, first: 1) {
          nodes {
            id
          }
        }
      }
    }
  }
  """

  # `orderBy: createdAt` is kept explicit so consumers can rely on a deterministic
  # within-page ordering regardless of Linear's default (`updatedAt`). Pagination
  # via `pageInfo { hasNextPage endCursor }` guarantees `fetch_comments/1` returns
  # every comment on the issue — including the `## Symphony Workpad` marker — even
  # when the issue has more than `@comments_page_size` comments (IDE-103).
  @comments_query """
  query SymphonyIssueComments($issueId: String!, $first: Int!, $after: String) {
    issue(id: $issueId) {
      comments(first: $first, after: $after, orderBy: createdAt) {
        nodes {
          id
          body
          resolvedAt
        }
        pageInfo {
          hasNextPage
          endCursor
        }
      }
    }
  }
  """

  @update_comment_mutation """
  mutation SymphonyUpdateComment($id: String!, $body: String!) {
    commentUpdate(id: $id, input: {body: $body}) {
      success
    }
  }
  """

  @comments_page_size 50

  # Comment-specific pagination cap. `Pagination`'s shared default (20 pages /
  # ~1000 items) is sized for issue lists; a single busy issue can legitimately
  # carry far more comments, so `fetch_comments/1` opts into a more generous
  # budget: 50 pages x @comments_page_size = 2500 comments before we give up.
  # That is well above any realistic real-world comment count yet still bounds
  # an externally-driven loop (a server advertising `hasNextPage: true` forever)
  # to a finite number of network round-trips.
  @max_comment_pages 50

  @spec max_comment_pages() :: pos_integer()
  def max_comment_pages, do: @max_comment_pages

  @spec fetch_candidate_issues() :: {:ok, [term()]} | {:error, term()}
  def fetch_candidate_issues, do: client_module().fetch_candidate_issues()

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [term()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids), do: client_module().fetch_issue_states_by_ids(issue_ids)

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@create_comment_mutation, %{issueId: issue_id, body: body}),
         true <- get_in(response, ["data", "commentCreate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_create_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_create_failed}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(issue_id, state_name),
         {:ok, response} <-
           client_module().graphql(@update_state_mutation, %{issueId: issue_id, stateId: state_id}),
         true <- get_in(response, ["data", "issueUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :issue_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :issue_update_failed}
    end
  end

  @spec fetch_comments(String.t()) ::
          {:ok, [SymphonyElixir.Tracker.comment()]}
          | {:error, :comment_pagination_exceeded}
          | {:error, term()}
  def fetch_comments(issue_id) when is_binary(issue_id) do
    case Pagination.paginate(&fetch_comments_page(issue_id, &1), max_pages: @max_comment_pages) do
      # Collapse both pagination safety-valve trips — the hard page cap and a
      # non-advancing (stuck) cursor — into one loud error. We deliberately fail
      # rather than return partial comments: this result feeds the
      # deterministic-failure escalation path, where a silently-truncated comment
      # list could hide the `## Symphony Workpad` marker and corrupt escalation
      # decisions. Failing loud is the safer outcome (IDE-110).
      {:error, reason} when reason in [:linear_pagination_exhausted, :linear_stuck_cursor] ->
        {:error, :comment_pagination_exceeded}

      other ->
        other
    end
  end

  defp fetch_comments_page(issue_id, after_cursor) do
    with {:ok, response} <-
           client_module().graphql(@comments_query, %{
             issueId: issue_id,
             first: @comments_page_size,
             after: after_cursor
           }),
         %{"nodes" => nodes} = comments when is_list(nodes) <-
           get_in(response, ["data", "issue", "comments"]) do
      {:ok, Enum.map(nodes, &normalize_comment/1), normalize_page_info(Map.get(comments, "pageInfo"))}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comments_fetch_failed}
    end
  end

  defp normalize_page_info(%{"hasNextPage" => has_next} = page_info) do
    %{has_next_page: has_next == true, end_cursor: Map.get(page_info, "endCursor")}
  end

  defp normalize_page_info(_), do: %{has_next_page: false, end_cursor: nil}

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) when is_binary(comment_id) and is_binary(body) do
    with {:ok, response} <- client_module().graphql(@update_comment_mutation, %{id: comment_id, body: body}),
         true <- get_in(response, ["data", "commentUpdate", "success"]) == true do
      :ok
    else
      false -> {:error, :comment_update_failed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :comment_update_failed}
    end
  end

  defp normalize_comment(node) do
    %{
      id: Map.get(node, "id"),
      body: Map.get(node, "body", ""),
      resolved_at: Map.get(node, "resolvedAt")
    }
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :linear_client_module, Client)
  end

  defp resolve_state_id(issue_id, state_name) do
    with {:ok, response} <-
           client_module().graphql(@state_lookup_query, %{issueId: issue_id, stateName: state_name}),
         state_id when is_binary(state_id) <-
           get_in(response, ["data", "issue", "team", "states", "nodes", Access.at(0), "id"]) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end
end
