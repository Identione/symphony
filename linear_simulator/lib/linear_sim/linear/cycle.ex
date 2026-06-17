defmodule LinearSim.Linear.Cycle do
  @moduledoc "A simulated Linear cycle (sprint). Minimal; not yet queried by symphony."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "cycles" do
    field :name, :string
    field :number, :integer

    belongs_to :team, LinearSim.Linear.Team

    timestamps()
  end

  @doc false
  def changeset(cycle, attrs) do
    cycle
    |> cast(attrs, [:id, :team_id, :name, :number])
    |> validate_required([:id, :team_id])
  end
end
