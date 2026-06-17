defmodule LinearSim.Linear.Organization do
  @moduledoc "A simulated Linear organization (workspace)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "organizations" do
    field :name, :string
    field :url_key, :string

    has_many :users, LinearSim.Linear.User
    has_many :teams, LinearSim.Linear.Team
    has_many :projects, LinearSim.Linear.Project

    timestamps()
  end

  @doc false
  def changeset(org, attrs) do
    org
    |> cast(attrs, [:id, :name, :url_key])
    |> validate_required([:id, :name, :url_key])
    |> unique_constraint(:url_key)
  end
end
