defmodule SymphonyElixir.Tracker.Memory do
  @moduledoc """
  In-memory tracker adapter used for tests and local development.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    {:ok, issue_entries()}
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{state: state} ->
       MapSet.member?(normalized_states, normalize_state(state))
     end)}
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) do
    wanted_ids = MapSet.new(issue_ids)

    {:ok,
     Enum.filter(issue_entries(), fn %Issue{id: id} ->
       MapSet.member?(wanted_ids, id)
     end)}
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) do
    with_injection(:memory_tracker_create_comment_response, fn ->
      maybe_delay(:memory_tracker_create_comment_delay_ms)
      send_event({:memory_tracker_comment, issue_id, body})
      :ok
    end)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) do
    with_injection(:memory_tracker_update_issue_state_response, fn ->
      maybe_delay(:memory_tracker_update_issue_state_delay_ms)
      send_event({:memory_tracker_state_update, issue_id, state_name})
      :ok
    end)
  end

  @spec fetch_comments(String.t()) :: {:ok, [SymphonyElixir.Tracker.comment()]} | {:error, term()}
  def fetch_comments(issue_id) do
    with_injection(:memory_tracker_fetch_comments_response, fn ->
      maybe_delay(:memory_tracker_fetch_comments_delay_ms)

      comments =
        :symphony_elixir
        |> Application.get_env(:memory_tracker_comments, %{})
        |> Map.get(issue_id, [])

      {:ok, comments}
    end)
  end

  @spec update_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def update_comment(comment_id, body) do
    with_injection(:memory_tracker_update_comment_response, fn ->
      maybe_delay(:memory_tracker_update_comment_delay_ms)
      send_event({:memory_tracker_comment_update, comment_id, body})
      :ok
    end)
  end

  defp configured_issues do
    Application.get_env(:symphony_elixir, :memory_tracker_issues, [])
  end

  defp issue_entries do
    Enum.filter(configured_issues(), &match?(%Issue{}, &1))
  end

  defp send_event(message) do
    case Application.get_env(:symphony_elixir, :memory_tracker_recipient) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end

  # Test-only injection point: tests set e.g.
  # `Application.put_env(:symphony_elixir, :memory_tracker_update_comment_response, {:error, :boom})`
  # to drive the DeterministicFailure `{:error, _}` branches without a real
  # GraphQL transport.
  defp with_injection(key, fun) do
    case Application.get_env(:symphony_elixir, key) do
      {:error, _} = err -> err
      _ -> fun.()
    end
  end

  # Test-only knob: tests set e.g.
  # `Application.put_env(:symphony_elixir, :memory_tracker_fetch_comments_delay_ms, 200)`
  # to simulate a slow Tracker round-trip. Used by IDE-102 to assert
  # `DeterministicFailure.handle/3` runs off the orchestrator GenServer so a
  # slow Linear API call does not stall dispatch for other issues.
  defp maybe_delay(key) do
    case Application.get_env(:symphony_elixir, key) do
      ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  defp normalize_state(state) when is_binary(state) do
    state
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_state(_state), do: ""
end
