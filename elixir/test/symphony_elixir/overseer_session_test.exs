defmodule SymphonyElixir.Overseer.SessionTest do
  @moduledoc """
  Run-scoped overseer state (IDE-212): the bounded transcript ring buffer and the
  call bookkeeping (`calls` / `last_call_turn`) that backs the cooldown + cap.
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.Overseer.Session

  defp env(n), do: %{event: :assistant_message, payload: %{text: "m#{n}"}}

  test "keeps only the last `window` envelopes, oldest-first" do
    {:ok, pid} = Session.start_link(3)
    for n <- 1..5, do: Session.record(pid, env(n))

    texts = pid |> Session.transcript() |> Enum.map(& &1.payload.text)
    assert texts == ["m3", "m4", "m5"]
  end

  test "a zero window records nothing" do
    {:ok, pid} = Session.start_link(0)
    Session.record(pid, env(1))
    assert Session.transcript(pid) == []
  end

  test "call bookkeeping bumps calls and tracks the last call turn" do
    {:ok, pid} = Session.start_link(10)
    assert %{calls: 0, last_call_turn: nil} = Session.stats(pid)

    Session.register_call(pid, 16)
    assert %{calls: 1, last_call_turn: 16} = Session.stats(pid)

    Session.register_call(pid, 19)
    assert %{calls: 2, last_call_turn: 19} = Session.stats(pid)
  end

  test "stop/1 tears the session down" do
    {:ok, pid} = Session.start_link(1)
    assert :ok = Session.stop(pid)
    refute Process.alive?(pid)
  end
end
