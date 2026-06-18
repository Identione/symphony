defmodule LinearSim.Linear.ApiToken do
  @moduledoc "Bearer token mapping to a user/org for simulator auth context."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "api_tokens" do
    field :token, :string
    field :label, :string

    belongs_to :organization, LinearSim.Linear.Organization
    belongs_to :user, LinearSim.Linear.User

    timestamps()
  end

  @doc false
  def changeset(token, attrs) do
    token
    |> cast(attrs, [:id, :organization_id, :user_id, :token, :label])
    |> validate_required([:id, :organization_id, :user_id, :token])
    |> unique_constraint(:token)
  end
end
