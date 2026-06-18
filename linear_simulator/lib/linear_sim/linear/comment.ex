defmodule LinearSim.Linear.Comment do
  @moduledoc "A simulated Linear issue comment. `resolved_at` is read by symphony."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "comments" do
    field :body, :string
    field :resolved_at, :utc_datetime_usec

    belongs_to :issue, LinearSim.Linear.Issue
    belongs_to :user, LinearSim.Linear.User

    timestamps()
  end

  @doc false
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:id, :issue_id, :user_id, :body, :resolved_at])
    |> validate_required([:id, :issue_id, :body])
  end
end
