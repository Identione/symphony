defmodule LinearSim.Linear.WorkflowState do
  @moduledoc "A team workflow state (e.g. Todo, In Progress, Done)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "workflow_states" do
    field :name, :string
    field :type, :string
    field :color, :string
    field :position, :integer

    belongs_to :team, LinearSim.Linear.Team

    timestamps()
  end

  @doc false
  def changeset(state, attrs) do
    state
    |> cast(attrs, [:id, :team_id, :name, :type, :color, :position])
    |> validate_required([:id, :team_id, :name, :type])
  end
end
