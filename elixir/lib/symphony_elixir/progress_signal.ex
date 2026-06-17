defmodule SymphonyElixir.ProgressSignal do
  @moduledoc """
  Layer 1 of the IDE-189 agent-run robustness defense: deterministic, per-turn
  progress signals computed from cheap git/workspace probes.

  This module is the *pure* decision core. The orchestrator owns the per-issue
  rolling state (stored on the `running` entry under `:progress`), runs the git
  probe at each turn boundary, and feeds the observation here via `advance/3`.
  No IO lives in this module — git access is the `SymphonyElixir.Git` helper's
  job — which keeps the classifier unit-testable against a synthetic turn
  sequence (notably the IDE-189 replay corpus).

  ## What it computes

  Per turn boundary we observe three raw inputs:

    * `hash`         — a content hash of the working tree (tracked + untracked,
      via `git write-tree` on a throwaway index). Identical hash across turns ⇒
      the agent changed nothing this turn.
    * `empty`        — whether `git status --porcelain` is empty (clean tree).
    * `commits_since`— commits on HEAD since the dispatch marker.

  plus an optional per-turn `error_sig` (a stable adapter-tagged terminal-error
  signature, or `nil` when the turn ended without a terminal error).

  From the rolling streaks of those we derive a `t:status/0` and an independent
  `at_risk_no_commits` boolean:

      :oscillating     last 4 hashes are A,B,A,B with A != B
      :repeated_error  error_sig != nil AND its streak >= K
      :stuck_state     identical hash for >= K turns AND the tree is empty
      :progressing     otherwise

      at_risk_no_commits = commits_since == 0 AND turn_count >= K

  ## The empty-tree guard (why `:no_commits` is a flag, not a status)

  The IDE-189 replay showed a build-heavy issue holding a *dirty* tree (one
  pending edit) for many turns while producing 0 commits. A naive
  "identical-hash-for-K-turns ⇒ stuck" rule misclassifies that as stuck once the
  edits stop. The fix: `:stuck_state` only fires on an **empty** working tree —
  a dirty-but-identical tree is `:progressing` carrying `at_risk_no_commits`,
  never `:stuck`. So `at_risk_no_commits` is a parallel boolean that coexists
  with `:progressing`; it is never a status value.

  ## Non-enforcement contract

  Layer 1 only *reports*. The statuses and the flag are surfaced to the
  dashboard, logged, and fed to `trigger?/2` (the predicate Layer 2 consumes).
  Nothing here kills a session, moves a Linear state, or gates continuation —
  those belong to Layers 0/2.
  """

  alias SymphonyElixir.Config.Schema

  @typedoc "Most→least severe progress classification for a single turn boundary."
  @type status :: :progressing | :stuck_state | :oscillating | :repeated_error

  @typedoc "Adapter-tagged terminal-error signature for a turn, or `nil`."
  @type error_sig :: {:claude | :codex, atom()} | nil

  @typedoc """
  Result struct returned to consumers (dashboard / `trigger?/2`) and logged.
  `at_risk_no_commits` is independent of `status` (see the moduledoc).
  """
  @type assessment :: %{
          status: status(),
          at_risk_no_commits: boolean(),
          # Empty before the first turn (see `default_assessment/0`); otherwise
          # carries tree_hash_streak / commits_since / error_sig / error_sig_streak
          # / wt_empty / turn_count.
          evidence: map()
        }

  @typedoc """
  Per-issue rolling state. The orchestrator stores this on the `running` entry
  under `:progress` and threads it back through `advance/3` each turn boundary.
  `dispatch_head` is owned by the orchestrator (captured lazily on first probe)
  and is carried here only so the whole signal lives in one map.
  """
  @type state :: %{
          tree_hash: String.t() | nil,
          tree_streak: non_neg_integer(),
          tree_history: [String.t()],
          error_sig: error_sig(),
          error_streak: non_neg_integer(),
          commits_since: non_neg_integer(),
          turn_count: non_neg_integer(),
          wt_empty: boolean(),
          dispatch_head: String.t() | nil,
          assessment: assessment()
        }

  @typedoc "Per-turn observation fed to `advance/3`."
  @type observation :: %{
          hash: String.t(),
          empty: boolean(),
          commits_since: non_neg_integer(),
          error_sig: error_sig(),
          turn_count: non_neg_integer()
        }

  # Oscillation needs the last four hashes to spot an A,B,A,B flip-flop.
  @history_limit 4

  @doc """
  The zero-state for a freshly dispatched issue (no turns observed yet).
  """
  @spec initial() :: state()
  def initial do
    %{
      tree_hash: nil,
      tree_streak: 0,
      tree_history: [],
      error_sig: nil,
      error_streak: 0,
      commits_since: 0,
      turn_count: 0,
      wt_empty: false,
      dispatch_head: nil,
      assessment: default_assessment()
    }
  end

  @doc """
  The neutral assessment reported before any turn has been observed (and the
  default the dashboard/snapshot falls back to).
  """
  @spec default_assessment() :: assessment()
  def default_assessment do
    %{status: :progressing, at_risk_no_commits: false, evidence: %{}}
  end

  @doc """
  Roll the rolling state forward by one turn-boundary observation and recompute
  the assessment. Pure — `dispatch_head` is preserved untouched.
  """
  @spec advance(state(), observation(), Schema.t()) :: state()
  def advance(state, observation, settings) do
    {tree_streak, history} = roll_tree(state, observation.hash)
    {error_sig, error_streak} = roll_error(state, observation.error_sig)

    advanced = %{
      state
      | tree_hash: observation.hash,
        tree_streak: tree_streak,
        tree_history: history,
        error_sig: error_sig,
        error_streak: error_streak,
        commits_since: observation.commits_since,
        turn_count: observation.turn_count,
        wt_empty: observation.empty
    }

    %{advanced | assessment: assess(advanced, settings)}
  end

  @doc """
  Classify the current rolling state into an `t:assessment/0`. Pure.
  """
  @spec assess(state(), Schema.t()) :: assessment()
  def assess(state, settings) do
    k = window_k(settings)

    %{
      status: classify(state, k),
      at_risk_no_commits: state.commits_since == 0 and state.turn_count >= k,
      evidence: %{
        tree_hash_streak: state.tree_streak,
        commits_since: state.commits_since,
        error_sig: state.error_sig,
        error_sig_streak: state.error_streak,
        wt_empty: state.wt_empty,
        turn_count: state.turn_count
      }
    }
  end

  @doc """
  The Layer-2 trigger predicate: `true` when the cheap signals warrant the
  expensive AI overseer. Layer 1 itself takes no action on this — it only
  reports the boolean.
  """
  @spec trigger?(assessment(), Schema.t()) :: boolean()
  def trigger?(%{status: status} = assessment, settings) do
    min_turns = settings.agent.progress_trigger_min_turns
    turn_count = Map.get(assessment.evidence, :turn_count, 0)

    status in [:stuck_state, :oscillating, :repeated_error] or
      (assessment.at_risk_no_commits and turn_count >= min_turns)
  end

  @doc "True when the assessment is `:stuck_state`."
  @spec stuck?(assessment()) :: boolean()
  def stuck?(%{status: status}), do: status == :stuck_state

  @doc "True when the assessment is `:oscillating`."
  @spec oscillating?(assessment()) :: boolean()
  def oscillating?(%{status: status}), do: status == :oscillating

  @doc "True when the assessment is `:repeated_error`."
  @spec repeated_error?(assessment()) :: boolean()
  def repeated_error?(%{status: status}), do: status == :repeated_error

  # ── internals ──────────────────────────────────────────────────────────────

  @spec classify(state(), pos_integer()) :: status()
  defp classify(state, k) do
    cond do
      oscillating_history?(state.tree_history) -> :oscillating
      not is_nil(state.error_sig) and state.error_streak >= k -> :repeated_error
      state.tree_streak >= k and state.wt_empty -> :stuck_state
      true -> :progressing
    end
  end

  # A,B,A,B with A != B over the last four boundaries (most-recent first).
  @spec oscillating_history?([String.t()]) :: boolean()
  defp oscillating_history?([a, b, a, b]) when a != b and is_binary(a) and is_binary(b), do: true
  defp oscillating_history?(_history), do: false

  # Streak counts consecutive identical hashes; history keeps the last
  # `@history_limit` hashes (most-recent first) for oscillation detection.
  @spec roll_tree(state(), String.t()) :: {non_neg_integer(), [String.t()]}
  defp roll_tree(%{tree_hash: prev, tree_streak: streak, tree_history: history}, hash) do
    new_streak = if hash == prev, do: streak + 1, else: 1
    {new_streak, Enum.take([hash | history], @history_limit)}
  end

  # `nil` (no terminal error this turn) breaks any prior error streak — a clean
  # turn means the errors are no longer *consecutive*. A repeated identical
  # signature advances the streak; a new signature restarts it at 1.
  @spec roll_error(state(), error_sig()) :: {error_sig(), non_neg_integer()}
  defp roll_error(_state, nil), do: {nil, 0}
  defp roll_error(%{error_sig: sig, error_streak: streak}, sig), do: {sig, streak + 1}
  defp roll_error(_state, sig), do: {sig, 1}

  @spec window_k(Schema.t()) :: pos_integer()
  defp window_k(settings), do: settings.agent.progress_signal_window_k
end
