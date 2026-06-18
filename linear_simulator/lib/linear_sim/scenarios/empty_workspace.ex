defmodule LinearSim.Scenarios.EmptyWorkspace do
  @moduledoc "The base workspace skeleton with no issues — exercises empty polls."
  alias LinearSim.Scenarios.Common

  @doc "Seeds an empty workspace. Must run inside the Scenarios transaction."
  @spec seed!() :: :ok
  def seed! do
    Common.base_workspace!()
    :ok
  end
end
