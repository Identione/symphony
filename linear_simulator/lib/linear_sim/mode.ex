defmodule LinearSim.Mode do
  @moduledoc """
  Holds the simulator's current GraphQL response mode, set by scenarios that
  exercise transport-level behaviour rather than data (e.g. `rate_limited`).

  `:normal` resolves queries as usual; `:rate_limited` makes `/graphql` return a
  Linear-style `RATELIMITED` error body so symphony's `RateLimit` breaker trips
  (docs/linear-sim.md §20).
  """

  @key {__MODULE__, :mode}

  @doc "Returns the current response mode (defaults to `:normal`)."
  @spec get() :: atom()
  def get, do: :persistent_term.get(@key, :normal)

  @doc "Sets the current response mode."
  @spec put(atom()) :: :ok
  def put(mode) when is_atom(mode), do: :persistent_term.put(@key, mode)
end
