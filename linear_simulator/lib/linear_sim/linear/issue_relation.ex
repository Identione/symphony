defmodule LinearSim.Linear.IssueRelation do
  @moduledoc """
  A directed relation between two issues (e.g. `blocks`, `blocked_by`,
  `related`, `duplicate`). `issue` is the source, `related_issue` the target.
  Symphony reads an issue's `inverseRelations` (relations where it is the
  target) to detect blockers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  schema "issue_relations" do
    field :type, :string

    belongs_to :issue, LinearSim.Linear.Issue
    belongs_to :related_issue, LinearSim.Linear.Issue

    timestamps()
  end

  @doc false
  def changeset(relation, attrs) do
    relation
    |> cast(attrs, [:id, :issue_id, :related_issue_id, :type])
    |> validate_required([:id, :issue_id, :related_issue_id, :type])
  end
end
