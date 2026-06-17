defmodule LinearSim.Linear.Issue do
  @moduledoc "A simulated Linear issue — the central entity symphony polls and updates."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "issues" do
    field :identifier, :string
    field :number, :integer
    field :title, :string
    field :description, :string
    field :priority, :integer
    field :branch_name, :string
    field :url, :string
    field :archived_at, :utc_datetime_usec

    belongs_to :organization, LinearSim.Linear.Organization
    belongs_to :team, LinearSim.Linear.Team
    belongs_to :state, LinearSim.Linear.WorkflowState
    belongs_to :assignee, LinearSim.Linear.User
    belongs_to :parent, LinearSim.Linear.Issue
    belongs_to :project, LinearSim.Linear.Project
    belongs_to :cycle, LinearSim.Linear.Cycle

    has_many :children, LinearSim.Linear.Issue, foreign_key: :parent_id
    has_many :comments, LinearSim.Linear.Comment

    # Relations where this issue is the source.
    has_many :relations, LinearSim.Linear.IssueRelation, foreign_key: :issue_id
    # Relations where this issue is the target (symphony's blocker check).
    has_many :inverse_relations, LinearSim.Linear.IssueRelation, foreign_key: :related_issue_id

    many_to_many :labels, LinearSim.Linear.Label,
      join_through: LinearSim.Linear.IssueLabel,
      join_keys: [issue_id: :id, label_id: :id]

    timestamps()
  end

  @doc false
  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [
      :id,
      :organization_id,
      :team_id,
      :state_id,
      :assignee_id,
      :parent_id,
      :project_id,
      :cycle_id,
      :identifier,
      :number,
      :title,
      :description,
      :priority,
      :branch_name,
      :url,
      :archived_at
    ])
    |> validate_required([:id, :organization_id, :team_id, :identifier, :number, :title])
    |> unique_constraint(:identifier)
  end
end
