defmodule SymphonyElixir.Overseer.Session do
  @moduledoc """
  Per-agent-run mutable state for the Layer 2 overseer (IDE-212), held in a tiny
  `Agent` so it survives across the worker's recursive turn loop without
  threading extra arguments through every call.

  It owns:

    * a bounded **transcript ring buffer** of the last N normalized envelopes
      (assistant text / tool calls / turn boundaries), accumulated by the
      `AgentRunner` message handler. The buffer is adapter-agnostic at the
      consumption point — both the codex and claude adapters feed the same
      normalized envelope shape.
    * the **call bookkeeping** (`calls` made this run + `last_call_turn`) that
      backs the cooldown / per-session cap.
    * the **worker-side progress state** (IDE-230): the Layer-1
      `ProgressSignal` rolling state, the consecutive deterministic fail-streak,
      the lazily-captured `dispatch_head` marker, and a one-shot
      `capped_comment_posted?` flag so the "could not judge" comment posts once.

  The process is started in `AgentRunner.run_codex_turns/5` and torn down in the
  same `after` block as the adapter session, so it is strictly run-scoped.
  """

  use Agent

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.ProgressSignal

  @typep state :: %{
           buffer: :queue.queue(map()),
           buffer_size: non_neg_integer(),
           window: non_neg_integer(),
           calls: non_neg_integer(),
           last_call_turn: non_neg_integer() | nil,
           progress: ProgressSignal.state(),
           fail_streak: non_neg_integer(),
           dispatch_head: String.t() | nil,
           capped_comment_posted?: boolean()
         }

  @doc "Start a run-scoped session holding a transcript window of `window` envelopes."
  @spec start_link(non_neg_integer()) :: Agent.on_start()
  def start_link(window) when is_integer(window) and window >= 0 do
    Agent.start_link(fn ->
      %{
        buffer: :queue.new(),
        buffer_size: 0,
        window: window,
        calls: 0,
        last_call_turn: nil,
        progress: ProgressSignal.initial(),
        fail_streak: 0,
        dispatch_head: nil,
        capped_comment_posted?: false
      }
    end)
  end

  @doc "Append one normalized transcript envelope, evicting the oldest past the window."
  @spec record(pid(), map()) :: :ok
  def record(pid, envelope) when is_pid(pid) and is_map(envelope) do
    Agent.update(pid, fn state -> push(state, envelope) end)
  end

  @doc "The current transcript window as a list, oldest-first."
  @spec transcript(pid()) :: [map()]
  def transcript(pid) when is_pid(pid) do
    Agent.get(pid, fn %{buffer: buffer} -> :queue.to_list(buffer) end)
  end

  @doc "Record that an overseer call fired on `turn` (bumps `calls`, sets `last_call_turn`)."
  @spec register_call(pid(), non_neg_integer()) :: :ok
  def register_call(pid, turn) when is_pid(pid) and is_integer(turn) do
    Agent.update(pid, fn state ->
      %{state | calls: state.calls + 1, last_call_turn: turn}
    end)
  end

  @doc "Call bookkeeping snapshot for the trigger predicate."
  @spec stats(pid()) :: %{calls: non_neg_integer(), last_call_turn: non_neg_integer() | nil}
  def stats(pid) when is_pid(pid) do
    Agent.get(pid, fn %{calls: calls, last_call_turn: last} ->
      %{calls: calls, last_call_turn: last}
    end)
  end

  @doc """
  Advance the worker-side `ProgressSignal` state by one turn-boundary
  observation (IDE-230) and update the consecutive deterministic fail-streak: a
  turn that trips `ProgressSignal.trigger?/2` bumps the streak, any passing turn
  resets it to 0. Returns the new `{assessment, fail_streak}`.
  """
  @spec advance_progress(pid(), ProgressSignal.observation(), Schema.t()) ::
          %{assessment: ProgressSignal.assessment(), fail_streak: non_neg_integer()}
  def advance_progress(pid, observation, settings) when is_pid(pid) and is_map(observation) do
    Agent.get_and_update(pid, fn state ->
      progress = ProgressSignal.advance(state.progress, observation, settings)
      assessment = progress.assessment
      streak = if ProgressSignal.trigger?(assessment, settings), do: state.fail_streak + 1, else: 0
      result = %{assessment: assessment, fail_streak: streak}
      {result, %{state | progress: progress, fail_streak: streak}}
    end)
  end

  @doc "Reset the consecutive deterministic fail-streak (called when the overseer approves)."
  @spec reset_fail_streak(pid()) :: :ok
  def reset_fail_streak(pid) when is_pid(pid) do
    Agent.update(pid, fn state -> %{state | fail_streak: 0} end)
  end

  @doc "The lazily-captured dispatch HEAD marker (`nil` until the first probe)."
  @spec dispatch_head(pid()) :: String.t() | nil
  def dispatch_head(pid) when is_pid(pid) do
    Agent.get(pid, & &1.dispatch_head)
  end

  @doc "Capture the dispatch HEAD marker on first probe (no-op once set)."
  @spec put_dispatch_head(pid(), String.t() | nil) :: :ok
  def put_dispatch_head(pid, head) when is_pid(pid) do
    Agent.update(pid, fn
      %{dispatch_head: nil} = state when is_binary(head) -> %{state | dispatch_head: head}
      state -> state
    end)
  end

  @doc """
  Worker-side progress + call snapshot for the trigger decision and evidence:
  the latest `assessment`, the `fail_streak`, the call bookkeeping, and the
  one-shot capped-comment flag.
  """
  @spec progress_snapshot(pid()) :: %{
          assessment: ProgressSignal.assessment(),
          fail_streak: non_neg_integer(),
          calls: non_neg_integer(),
          last_call_turn: non_neg_integer() | nil,
          capped_comment_posted?: boolean()
        }
  def progress_snapshot(pid) when is_pid(pid) do
    Agent.get(pid, fn state ->
      %{
        assessment: state.progress.assessment,
        fail_streak: state.fail_streak,
        calls: state.calls,
        last_call_turn: state.last_call_turn,
        capped_comment_posted?: state.capped_comment_posted?
      }
    end)
  end

  @doc """
  Atomically mark the one-shot "could not judge" cap comment as posted. Returns
  `true` the first time (caller should post the comment) and `false` thereafter.
  """
  @spec claim_capped_comment(pid()) :: boolean()
  def claim_capped_comment(pid) when is_pid(pid) do
    Agent.get_and_update(pid, fn
      %{capped_comment_posted?: false} = state -> {true, %{state | capped_comment_posted?: true}}
      state -> {false, state}
    end)
  end

  @doc "Stop the run-scoped session."
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid), do: Agent.stop(pid)

  @spec push(state(), map()) :: state()
  defp push(%{window: 0} = state, _envelope), do: state

  defp push(%{buffer: buffer, buffer_size: size, window: window} = state, envelope) do
    appended = :queue.in(envelope, buffer)

    if size + 1 > window do
      {_dropped, trimmed} = :queue.out(appended)
      %{state | buffer: trimmed, buffer_size: window}
    else
      %{state | buffer: appended, buffer_size: size + 1}
    end
  end
end
