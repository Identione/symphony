defmodule LinearSim.Scenarios.WebhookDemo do
  @moduledoc "The basic workspace, used as the source state for webhook replay demos."
  alias LinearSim.Scenarios.BasicWorkspace

  @doc "Seeds the basic workspace."
  @spec seed!() :: :ok
  def seed!, do: BasicWorkspace.seed!()
end
