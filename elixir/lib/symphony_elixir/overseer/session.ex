defmodule SymphonyElixir.Overseer.Session do
  @moduledoc """
  Per-agent-run mutable state for the Layer 2 overseer (IDE-212), held in a tiny
  `Agent` so it survives across the worker's recursive turn loop without
  threading extra arguments through every call.

  It owns two things:

    * a bounded **transcript ring buffer** of the last N normalized envelopes
      (assistant text / tool calls / turn boundaries), accumulated by the
      `AgentRunner` message handler. The buffer is adapter-agnostic at the
      consumption point — both the codex and claude adapters feed the same
      normalized envelope shape.
    * the **call bookkeeping** (`calls` made this run + `last_call_turn`) that
      backs the cooldown / per-session cap so the budget-threshold trigger does
      not re-fire every turn from K down to 0.

  The process is started in `AgentRunner.run_codex_turns/5` and torn down in the
  same `after` block as the adapter session, so it is strictly run-scoped.
  """

  use Agent

  @typep state :: %{
           buffer: :queue.queue(map()),
           buffer_size: non_neg_integer(),
           window: non_neg_integer(),
           calls: non_neg_integer(),
           last_call_turn: non_neg_integer() | nil
         }

  @doc "Start a run-scoped session holding a transcript window of `window` envelopes."
  @spec start_link(non_neg_integer()) :: Agent.on_start()
  def start_link(window) when is_integer(window) and window >= 0 do
    Agent.start_link(fn ->
      %{buffer: :queue.new(), buffer_size: 0, window: window, calls: 0, last_call_turn: nil}
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
