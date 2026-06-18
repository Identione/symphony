defmodule LinearSim.Scenarios.PermissionDenied do
  @moduledoc """
  The base workspace, but `/graphql` returns a Linear-style authorization
  (`FORBIDDEN`) error for every request (response mode set by
  `Scenarios.load!/1`). Exercises a client's permission-failure handling.
  """
  alias LinearSim.Scenarios.Common

  @doc "Seeds the base workspace. Response mode is applied by the dispatcher."
  @spec seed!() :: :ok
  def seed! do
    Common.base_workspace!()
    :ok
  end
end
