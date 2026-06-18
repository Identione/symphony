defmodule LinearSim.Repo.Migrations.CreateAttachments do
  use Ecto.Migration

  @moduledoc """
  Attachments — links recorded on an issue (e.g. a PR URL). Ownership cascades
  from the issue (docs/linear-sim.md §8). `(issue_id, url)` is unique so the
  link* mutations can reject duplicates and `attachmentCreate` can upsert,
  matching live Linear's behavior.
  """

  def change do
    create table(:attachments, primary_key: false) do
      add :id, :string, primary_key: true

      add :issue_id,
          references(:issues, type: :string, on_delete: :delete_all),
          null: false

      add :creator_id,
          references(:users, type: :string, on_delete: :nilify_all)

      add :title, :string, null: false
      add :url, :string, null: false
      add :subtitle, :string
      add :source_type, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:attachments, [:issue_id])
    create unique_index(:attachments, [:issue_id, :url])
  end
end
