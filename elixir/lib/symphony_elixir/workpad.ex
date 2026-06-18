defmodule SymphonyElixir.Workpad do
  @moduledoc """
  Locating the per-issue `## Symphony Workpad` comment on a Linear issue.

  The workpad comment holds the agent's plan + acceptance criteria. It is shared
  by two consumers: `SymphonyElixir.DeterministicFailure` (which appends its
  escalation section to it) and the Layer-2 overseer evidence path
  (`SymphonyElixir.AgentRunner`, IDE-230 — which feeds the plan to the overseer
  so it can judge progress against the acceptance criteria).

  Resolved (Linear-resolved) comments are skipped so a stale workpad is ignored.
  """

  alias SymphonyElixir.Tracker

  @marker "## Symphony Workpad"

  @doc "The marker string that identifies a workpad comment."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc """
  Find the active workpad comment for an issue. Returns `{:ok, comment}` (the
  `Tracker.fetch_comments/1` map shape), `:not_found`, or `{:error, reason}`.
  """
  @spec find(String.t()) :: {:ok, map()} | :not_found | {:error, term()}
  def find(issue_id) when is_binary(issue_id) do
    case Tracker.fetch_comments(issue_id) do
      {:ok, comments} ->
        case Enum.find(comments, &candidate?/1) do
          nil -> :not_found
          comment -> {:ok, comment}
        end

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Best-effort workpad body text for an issue, or `nil` when not found / on error.
  Suitable as fail-open evidence.
  """
  @spec text(String.t()) :: String.t() | nil
  def text(issue_id) when is_binary(issue_id) do
    case find(issue_id) do
      {:ok, %{body: body}} when is_binary(body) -> body
      _ -> nil
    end
  end

  @doc "True when a fetched comment is an active (unresolved) workpad comment."
  @spec candidate?(map()) :: boolean()
  def candidate?(%{body: body} = comment) when is_binary(body) do
    is_nil(Map.get(comment, :resolved_at)) and String.contains?(body, @marker)
  end

  def candidate?(_comment), do: false
end
