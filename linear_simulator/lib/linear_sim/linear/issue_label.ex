defmodule LinearSim.Linear.IssueLabel do
  @moduledoc "Join row between issues and labels."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "issue_labels" do
    belongs_to :issue, LinearSim.Linear.Issue
    belongs_to :label, LinearSim.Linear.Label

    timestamps()
  end

  @doc false
  def changeset(issue_label, attrs) do
    issue_label
    |> cast(attrs, [:id, :issue_id, :label_id])
    |> validate_required([:id, :issue_id, :label_id])
    |> unique_constraint([:issue_id, :label_id])
  end
end
