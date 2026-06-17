defmodule LinearSim.Scenarios do
  @moduledoc """
  Scenarios are the source of truth for simulator state (docs/linear-sim.md §17).

  Each `load!/1` wipes all tables bottom-up inside a transaction, then runs a
  scenario seed module. Seed modules must NOT open their own transaction — the
  transaction is owned here.
  """
  alias LinearSim.Repo

  alias LinearSim.Linear.{
    ApiToken,
    Comment,
    Cycle,
    Issue,
    IssueLabel,
    IssueRelation,
    Label,
    Organization,
    Project,
    Team,
    User,
    WebhookDelivery,
    WorkflowState
  }

  @scenarios %{
    "basic_workspace" => LinearSim.Scenarios.BasicWorkspace,
    "empty_workspace" => LinearSim.Scenarios.EmptyWorkspace,
    "many_issues" => LinearSim.Scenarios.ManyIssues,
    "archived_issues" => LinearSim.Scenarios.ArchivedIssues,
    "webhook_demo" => LinearSim.Scenarios.WebhookDemo,
    "rate_limited" => LinearSim.Scenarios.RateLimited
  }

  # Scenarios that put the GraphQL endpoint into a non-normal response mode.
  @modes %{"rate_limited" => :rate_limited}

  @default_scenario "basic_workspace"

  @doc "Names of all known scenarios."
  @spec names() :: [String.t()]
  def names, do: Map.keys(@scenarios)

  @doc "Resets the simulator to the default scenario."
  @spec reset!() :: :ok
  def reset!, do: load!(@default_scenario)

  @doc """
  Loads a named scenario, returning `{:error, :unknown_scenario}` for unknown
  names rather than raising.
  """
  @spec load(String.t()) :: :ok | {:error, :unknown_scenario}
  def load(name) do
    if Map.has_key?(@scenarios, name) do
      load!(name)
    else
      {:error, :unknown_scenario}
    end
  end

  @doc "Loads a named scenario, raising on an unknown name."
  @spec load!(String.t()) :: :ok
  def load!(name) do
    module = Map.fetch!(@scenarios, name)

    {:ok, _} =
      Repo.transaction(fn ->
        wipe_inside_transaction!()
        module.seed!()
      end)

    LinearSim.Mode.put(Map.get(@modes, name, :normal))
    :ok
  end

  defp wipe_inside_transaction! do
    # Bottom-up: delete children before parents. Cascades are a safety net,
    # not a replacement for predictable order (§8).
    Repo.delete_all(WebhookDelivery)
    Repo.delete_all(IssueLabel)
    Repo.delete_all(IssueRelation)
    Repo.delete_all(Comment)
    Repo.delete_all(Issue)
    Repo.delete_all(Label)
    Repo.delete_all(Cycle)
    Repo.delete_all(Project)
    Repo.delete_all(WorkflowState)
    Repo.delete_all(Team)
    Repo.delete_all(ApiToken)
    Repo.delete_all(User)
    Repo.delete_all(Organization)
  end
end
