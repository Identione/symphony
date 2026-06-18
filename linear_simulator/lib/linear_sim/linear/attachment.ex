defmodule LinearSim.Linear.Attachment do
  @moduledoc """
  A simulated Linear attachment (a link recorded on an issue, e.g. a PR URL).

  `(issue_id, url)` is unique: the link* mutations reject a duplicate while
  `attachmentCreate` upserts — matching live Linear (verified 2026-06-18). The
  simulator stores literal inputs only; it does not replicate Linear's async
  GitHub enrichment (sourceType/source/metadata backfill).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "attachments" do
    field :title, :string
    field :url, :string
    field :subtitle, :string
    field :source_type, :string

    belongs_to :issue, LinearSim.Linear.Issue
    belongs_to :creator, LinearSim.Linear.User

    timestamps()
  end

  @doc false
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:id, :issue_id, :creator_id, :title, :url, :subtitle, :source_type])
    |> validate_required([:id, :issue_id, :title, :url])
    |> unique_constraint([:issue_id, :url], name: :attachments_issue_id_url_index)
  end
end
