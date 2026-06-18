defmodule LinearSim.Linear.Label do
  @moduledoc "A simulated Linear issue label."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "labels" do
    field :name, :string
    field :color, :string

    belongs_to :organization, LinearSim.Linear.Organization

    many_to_many :issues, LinearSim.Linear.Issue,
      join_through: LinearSim.Linear.IssueLabel,
      join_keys: [label_id: :id, issue_id: :id]

    timestamps()
  end

  @doc false
  def changeset(label, attrs) do
    label
    |> cast(attrs, [:id, :organization_id, :name, :color])
    |> validate_required([:id, :organization_id, :name])
  end
end
