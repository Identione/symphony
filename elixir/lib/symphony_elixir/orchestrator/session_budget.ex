defmodule SymphonyElixir.Orchestrator.SessionBudget do
  @moduledoc """
  Restart-durable, per-issue session counter backing the cumulative
  `agent.max_sessions_per_issue` cap (P1/R1(a)).

  The orchestrator keeps the live counter in its in-memory `State`; this module
  is the *persistence* layer that lets that counter survive a daemon restart or
  `make upgrade`. It is a thin wrapper over a DETS table keyed by Linear issue
  id, holding `%{generation, count}` per issue:

    * `count` — sessions run in the current episode (bumped on each launch).
    * `generation` — advanced when the issue leaves the active set, so a fresh
      re-entry (e.g. a human moving an escalated issue back to `Todo`) starts a
      new episode with `count: 0` rather than re-escalating off the stale tally.

  Persistence is opt-in by path: when no path is configured (dev/test, or a
  run without an instance `run/` dir) `open/1` returns a `nil` handle and every
  operation is a no-op — the in-memory counter still enforces the cap within a
  single daemon lifetime, it just doesn't persist. The instance launcher wires
  the path from `--logs-root` (see `SymphonyElixir.CLI`), mirroring how the
  rotating disk log is located. DETS open failures degrade to the same `nil`
  (in-memory only) rather than crashing the orchestrator boot.
  """

  require Logger

  @typedoc "Persisted per-issue episode tally."
  @type entry :: %{generation: non_neg_integer(), count: non_neg_integer()}

  @typedoc "Opaque DETS handle, or `nil` when persistence is disabled."
  @type handle :: atom() | nil

  @doc """
  Open (creating if absent) the DETS table at `path` and return
  `{handle, loaded_counts}`. A `nil` path — or any open failure — yields
  `{nil, %{}}` (persistence disabled, in-memory only).
  """
  @spec open(Path.t() | nil) :: {handle(), %{optional(String.t()) => entry()}}
  def open(nil), do: {nil, %{}}

  def open(path) when is_binary(path) do
    expanded = Path.expand(path)
    table = table_name(expanded)

    with :ok <- File.mkdir_p(Path.dirname(expanded)),
         {:ok, ^table} <-
           :dets.open_file(table,
             file: String.to_charlist(expanded),
             type: :set,
             auto_save: 1_000
           ) do
      {table, load(table)}
    else
      other ->
        Logger.warning("Session-budget persistence disabled; could not open DETS at #{expanded}: #{inspect(other)}")

        {nil, %{}}
    end
  end

  @doc """
  Persist (insert/overwrite) the episode tally for `issue_id`. No-op when the
  handle is `nil`.
  """
  @spec put(handle(), String.t(), entry()) :: :ok
  def put(nil, _issue_id, _entry), do: :ok

  def put(table, issue_id, %{generation: _, count: _} = entry) when is_binary(issue_id) do
    :dets.insert(table, {issue_id, entry})
    :ok
  end

  @doc """
  Read every persisted tally as an `issue_id => entry` map. Used on boot to
  re-seed the in-memory counter.
  """
  @spec load(handle()) :: %{optional(String.t()) => entry()}
  def load(nil), do: %{}

  def load(table) do
    :dets.foldl(fn {issue_id, entry}, acc -> Map.put(acc, issue_id, entry) end, %{}, table)
  end

  @doc "Close the DETS table (flushing to disk). No-op when the handle is `nil`."
  @spec close(handle()) :: :ok
  def close(nil), do: :ok

  def close(table) do
    _ = :dets.close(table)
    :ok
  end

  # Derive a stable table atom from the file path. Bounded by the number of
  # distinct DETS paths a node ever opens (a handful), so this can't bloat the
  # atom table.
  @spec table_name(Path.t()) :: atom()
  defp table_name(path) do
    String.to_atom("symphony_session_budget_" <> Integer.to_string(:erlang.phash2(path)))
  end
end
