defmodule LinearSim.Scenarios.InvalidToken do
  @moduledoc """
  The base workspace, but `/graphql` returns a Linear-style authentication error
  for every request (response mode set by `Scenarios.load!/1`). Exercises a
  client's auth-failure handling regardless of the token sent.
  """
  alias LinearSim.Scenarios.Common

  @doc "Seeds the base workspace. Response mode is applied by the dispatcher."
  @spec seed!() :: :ok
  def seed! do
    Common.base_workspace!()
    :ok
  end
end
