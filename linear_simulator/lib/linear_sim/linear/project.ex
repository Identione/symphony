defmodule LinearSim.Linear.Project do
  @moduledoc "A simulated Linear project. `slug_id` is what symphony filters on."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "projects" do
    field :name, :string
    field :slug_id, :string

    belongs_to :organization, LinearSim.Linear.Organization

    timestamps()
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:id, :organization_id, :name, :slug_id])
    |> validate_required([:id, :organization_id, :name, :slug_id])
    |> unique_constraint(:slug_id)
  end
end
