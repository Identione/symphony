defmodule LinearSim.Linear.User do
  @moduledoc "A simulated Linear user."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "users" do
    field :name, :string
    field :email, :string

    belongs_to :organization, LinearSim.Linear.Organization

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:id, :organization_id, :name, :email])
    |> validate_required([:id, :organization_id, :name, :email])
  end
end
