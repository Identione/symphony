defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Locating the single persistent `## Symphony Workpad` comment on a Linear issue.

  The workpad carries the agent's plan + acceptance criteria and is the live
  source of truth for progress. Two consumers share this finder:

    * `SymphonyElixir.DeterministicFailure` — appends its escalation section to
      the workpad (or posts a standalone blocker when none exists).
    * `SymphonyElixir.AgentRunner` — feeds the workpad body to the Layer 2
      overseer (IDE-230) so the LLM judges progress against the plan.

  Only an *active* (unresolved) comment carrying the marker is eligible, matching
  the workflow's "ignore resolved comments while searching" rule.
  """

  alias SymphonyElixir.Tracker

  @marker "## Symphony Workpad"

  @doc "The marker header that identifies the persistent workpad comment."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Find the active workpad comment for an issue.

  Returns `{:ok, comment}` (the first unresolved comment containing the marker),
  `:not_found` when none match, or `{:error, reason}` when the comment fetch
  fails.
  """
  @spec find(String.t()) :: {:ok, map()} | :not_found | {:error, term()}
  def find(issue_id) when is_binary(issue_id) do
    case Tracker.fetch_comments(issue_id) do
      {:ok, comments} ->
        comments
        |> Enum.find(&candidate?/1)
        |> case do
          nil -> :not_found
          comment -> {:ok, comment}
        end

      {:error, _reason} = err ->
        err
    end
  end

  @doc "True when a comment is an active (unresolved) workpad comment."
  @spec candidate?(map()) :: boolean()
  def candidate?(%{body: body} = comment) when is_binary(body) do
    is_nil(Map.get(comment, :resolved_at)) and String.contains?(body, @marker)
  end

  def candidate?(_comment), do: false
end
