defmodule SymphonyElixir.Orchestrator.SessionBudgetStoreTest do
  @moduledoc """
  Unit coverage for the DETS-backed `SessionBudget` persistence layer that makes
  the cumulative per-issue session cap survive a daemon restart.
  """
  use ExUnit.Case, async: true

  alias SymphonyElixir.Orchestrator.SessionBudget

  defp tmp_path do
    name = "session_budget_store_#{System.unique_integer([:positive])}.dets"
    path = Path.join(System.tmp_dir!(), name)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a nil path disables persistence and every op is a no-op" do
    assert {nil, %{}} = SessionBudget.open(nil)
    assert :ok = SessionBudget.put(nil, "issue-1", %{generation: 1, count: 3})
    assert %{} = SessionBudget.load(nil)
    assert :ok = SessionBudget.close(nil)
  end

  test "put/load round-trips an entry within an open table" do
    path = tmp_path()
    {table, loaded} = SessionBudget.open(path)
    assert loaded == %{}

    :ok = SessionBudget.put(table, "issue-1", %{generation: 1, count: 2})
    :ok = SessionBudget.put(table, "issue-2", %{generation: 3, count: 7})

    assert SessionBudget.load(table) == %{
             "issue-1" => %{generation: 1, count: 2},
             "issue-2" => %{generation: 3, count: 7}
           }

    SessionBudget.close(table)
  end

  test "entries persist across a close/reopen (restart durability)" do
    path = tmp_path()

    {table, _} = SessionBudget.open(path)
    :ok = SessionBudget.put(table, "issue-1", %{generation: 2, count: 8})
    :ok = SessionBudget.close(table)

    # A fresh open (simulating a daemon restart) must see the persisted tally.
    {table2, loaded} = SessionBudget.open(path)
    assert loaded == %{"issue-1" => %{generation: 2, count: 8}}
    SessionBudget.close(table2)
  end

  test "put overwrites the prior entry for the same issue" do
    path = tmp_path()
    {table, _} = SessionBudget.open(path)

    :ok = SessionBudget.put(table, "issue-1", %{generation: 1, count: 1})
    :ok = SessionBudget.put(table, "issue-1", %{generation: 1, count: 2})

    assert SessionBudget.load(table) == %{"issue-1" => %{generation: 1, count: 2}}
    SessionBudget.close(table)
  end
end
