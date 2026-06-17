defmodule SymphonyElixir.ProgressSignal do
  @moduledoc """
  Layer 1 deterministic per-turn progress signals (IDE-189 / IDE-211).

  Pure decision logic over cheap, adapter-agnostic git signals computed once per
  turn boundary (claude `:turn_completed`, codex `:session_started`). The
  orchestrator owns the rolling per-issue state and the git IO
  (`SymphonyElixir.Git.working_tree_probe/4`); this module only rolls the
  streaks forward (`advance/2`) and classifies them (`assess/2`).

  ## Statuses (most → least severe)

      :oscillating     last 4 working-tree hashes are A,B,A,B with A != B
      :repeated_error  a terminal error signature repeated >= K turns
      :stuck_state     identical working-tree hash >= K turns AND the tree is EMPTY
      :progressing     otherwise

  The **empty-tree guard** on `:stuck_state` is the load-bearing design point
  surfaced by the IDE-189 replay: an issue with real pending work leaves a
  *dirty* tree, so an identical-dirty-tree run (e.g. builds that stop editing
  once a final state is reached) stays `:progressing`, never `:stuck`. Only an
  *empty* tree repeated K turns means the agent genuinely did nothing.

  Separately, `at_risk_no_commits` is an **independent boolean flag**, not a
  status value — it coexists with `:progressing` exactly because the motivating
  IDE-189 incident is "progressing-but-0-commits", which must NOT be reported as
  stuck.

  ## Non-enforcement contract

  Layer 1 only *reports* and *logs*. It never kills a session, moves a Linear
  state, or gates continuation. `trigger?/2` exposes a single boolean that
  Layer 2 (the AI overseer) consumes to decide whether the expensive check is
  warranted; acting on it is Layer 2's job, not this module's.
  """

  alias SymphonyElixir.Config.Schema

  @typedoc "One of the four deterministic per-turn statuses."
  @type status :: :progressing | :stuck_state | :oscillating | :repeated_error

  @typedoc "A stable, comparable terminal-error signature for a turn, or `nil`."
  @type error_sig :: term() | nil

  @typedoc """
  Rolling per-issue progress state, persisted on the orchestrator's running
  entry across turn boundaries.
  """
  @type t :: %{
          tree_hash: String.t() | nil,
          tree_streak: non_neg_integer(),
          tree_history: [String.t()],
          error_sig: error_sig(),
          error_streak: non_neg_integer(),
          commits_since: non_neg_integer(),
          wt_empty: boolean(),
          turn_count: non_neg_integer()
        }

  @typedoc "Raw per-turn inputs handed to `advance/2`."
  @type inputs :: %{
          required(:hash) => String.t(),
          required(:empty) => boolean(),
          required(:commits_since) => non_neg_integer(),
          required(:error_sig) => error_sig(),
          required(:turn_count) => non_neg_integer()
        }

  @typedoc "Resolved thresholds extracted from the workflow config."
  @type config :: %{required(:window_k) => pos_integer(), required(:trigger_min_turns) => pos_integer()}

  @typedoc "Result returned to consumers (snapshot, log, Layer 2)."
  @type assessment :: %{
          status: status(),
          at_risk_no_commits: boolean(),
          evidence: %{
            tree_hash_streak: non_neg_integer(),
            commits_since: non_neg_integer(),
            error_sig: error_sig(),
            error_sig_streak: non_neg_integer(),
            wt_empty: boolean(),
            turn_count: non_neg_integer()
          }
        }

  @history_window 4

  @doc "Fresh rolling state for a newly dispatched issue."
  @spec new() :: t()
  def new do
    %{
      tree_hash: nil,
      tree_streak: 0,
      tree_history: [],
      error_sig: nil,
      error_streak: 0,
      commits_since: 0,
      wt_empty: true,
      turn_count: 0
    }
  end

  @doc """
  Roll the streaks/history forward with one turn boundary's raw inputs. Pure.

  A working-tree hash identical to the previous turn extends `tree_streak`;
  otherwise it resets to 1. A `nil` `error_sig` means "no terminal error this
  turn" and zeroes the error streak; a repeated non-nil signature extends it.
  """
  @spec advance(t(), inputs()) :: t()
  def advance(state, %{hash: hash, empty: empty, commits_since: commits, error_sig: error_sig, turn_count: turn})
      when is_map(state) do
    tree_streak = if hash == state.tree_hash, do: state.tree_streak + 1, else: 1
    history = Enum.take([hash | state.tree_history], @history_window)

    {error_sig_out, error_streak} = advance_error(state, error_sig)

    %{
      state
      | tree_hash: hash,
        tree_streak: tree_streak,
        tree_history: history,
        error_sig: error_sig_out,
        error_streak: error_streak,
        commits_since: commits,
        wt_empty: empty,
        turn_count: turn
    }
  end

  defp advance_error(_state, nil), do: {nil, 0}

  defp advance_error(%{error_sig: prev, error_streak: streak}, sig) when sig == prev,
    do: {sig, streak + 1}

  defp advance_error(_state, sig), do: {sig, 1}

  @doc """
  Classify the rolled-forward state into an `assessment/0`. Pure.

  Precedence is most→least severe: `:oscillating`, `:repeated_error`,
  `:stuck_state` (empty-tree-gated), then `:progressing`. `at_risk_no_commits`
  is computed independently of the status.
  """
  @spec assess(t(), config()) :: assessment()
  def assess(state, %{window_k: k}) when is_map(state) do
    status =
      cond do
        oscillating?(state.tree_history) -> :oscillating
        not is_nil(state.error_sig) and state.error_streak >= k -> :repeated_error
        state.tree_streak >= k and state.wt_empty -> :stuck_state
        true -> :progressing
      end

    %{
      status: status,
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
  expensive AI overseer.

  Fires on any non-progressing status, or on the `at_risk_no_commits` flag once
  the turn count clears `trigger_min_turns`.
  """
  @spec trigger?(assessment(), config()) :: boolean()
  def trigger?(%{status: status, at_risk_no_commits: at_risk, evidence: %{turn_count: turns}}, %{
        trigger_min_turns: min_turns
      }) do
    status in [:stuck_state, :oscillating, :repeated_error] or
      (at_risk and turns >= min_turns)
  end

  @doc "Whether the assessment reports a stuck (empty-tree) state."
  @spec stuck?(assessment()) :: boolean()
  def stuck?(%{status: status}), do: status == :stuck_state

  @doc "The default assessment for an entry that has not been probed yet."
  @spec default_assessment() :: assessment()
  def default_assessment do
    %{
      status: :progressing,
      at_risk_no_commits: false,
      evidence: %{
        tree_hash_streak: 0,
        commits_since: 0,
        error_sig: nil,
        error_sig_streak: 0,
        wt_empty: true,
        turn_count: 0
      }
    }
  end

  @doc """
  Resolve the runtime thresholds from the workflow settings into the compact
  `config/0` this module operates on.
  """
  @spec config(Schema.t()) :: config()
  def config(%Schema{agent: agent}) do
    %{
      window_k: agent.progress_signal_window_k,
      trigger_min_turns: agent.progress_trigger_min_turns
    }
  end

  # A,B,A,B with A != B: the agent is flip-flopping between two tree states.
  defp oscillating?([a, b, a2, b2]) when a == a2 and b == b2 and a != b, do: true
  defp oscillating?(_history), do: false
end
