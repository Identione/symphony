defmodule LinearSim.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  This simulator uses file-backed SQLite with explicit scenario reset rather
  than the SQL sandbox (docs/linear-sim.md §5–6). Every test that touches
  simulator state must `use LinearSim.DataCase, async: false` — the shared DB
  file makes async runs non-deterministic.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias LinearSim.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import LinearSim.DataCase
    end
  end

  setup tags do
    LinearSim.DataCase.reset_state!(tags)
    :ok
  end

  @doc """
  Resets the simulator to the default scenario (or the one named by the
  `:scenario` tag) before each test.
  """
  def reset_state!(tags) do
    case tags[:scenario] do
      nil -> LinearSim.Scenarios.reset!()
      name -> LinearSim.Scenarios.load!(to_string(name))
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
