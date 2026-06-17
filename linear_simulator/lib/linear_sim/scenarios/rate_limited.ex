defmodule LinearSim.Scenarios.RateLimited do
  @moduledoc """
  The base workspace, but the GraphQL endpoint responds with a Linear-style
  `RATELIMITED` error body (the response mode is set by `Scenarios.load!/1`).
  Used to exercise symphony's rate-limit breaker.
  """
  alias LinearSim.Scenarios.Common

  @doc "Seeds the base workspace. Response mode is applied by the dispatcher."
  @spec seed!() :: :ok
  def seed! do
    Common.base_workspace!()
    :ok
  end
end
