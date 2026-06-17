defmodule LinearSim.Linear.Team do
  @moduledoc "A simulated Linear team. Owns workflow states and issues."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "teams" do
    field :key, :string
    field :name, :string

    belongs_to :organization, LinearSim.Linear.Organization
    has_many :workflow_states, LinearSim.Linear.WorkflowState
    has_many :issues, LinearSim.Linear.Issue

    timestamps()
  end

  @doc false
  def changeset(team, attrs) do
    team
    |> cast(attrs, [:id, :organization_id, :key, :name])
    |> validate_required([:id, :organization_id, :key, :name])
  end
end
