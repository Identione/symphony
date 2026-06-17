defmodule LinearSim.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  @moduledoc """
  Core simulator tables. String primary keys throughout for deterministic
  fixtures (docs/linear-sim.md §7) and `on_delete` policies per §8 — ownership
  relationships cascade, reference relationships nilify.
  """

  def change do
    create table(:organizations, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :url_key, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:organizations, [:url_key])

    create table(:users, primary_key: false) do
      add :id, :string, primary_key: true

      add :organization_id,
          references(:organizations, type: :string, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :email, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:users, [:organization_id])

    create table(:api_tokens, primary_key: false) do
      add :id, :string, primary_key: true

      add :organization_id,
          references(:organizations, type: :string, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :string, on_delete: :delete_all),
          null: false

      add :token, :string, null: false
      add :label, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:api_tokens, [:token])

    create table(:teams, primary_key: false) do
      add :id, :string, primary_key: true

      add :organization_id,
          references(:organizations, type: :string, on_delete: :delete_all),
          null: false

      add :key, :string, null: false
      add :name, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:teams, [:organization_id])

    create table(:workflow_states, primary_key: false) do
      add :id, :string, primary_key: true

      add :team_id,
          references(:teams, type: :string, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :type, :string, null: false
      add :position, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_states, [:team_id])

    create table(:projects, primary_key: false) do
      add :id, :string, primary_key: true

      add :organization_id,
          references(:organizations, type: :string, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :slug_id, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:projects, [:organization_id])
    create unique_index(:projects, [:slug_id])

    create table(:cycles, primary_key: false) do
      add :id, :string, primary_key: true

      add :team_id,
          references(:teams, type: :string, on_delete: :delete_all),
          null: false

      add :name, :string
      add :number, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create table(:labels, primary_key: false) do
      add :id, :string, primary_key: true

      add :organization_id,
          references(:organizations, type: :string, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :color, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:labels, [:organization_id])

    create table(:issues, primary_key: false) do
      add :id, :string, primary_key: true

      add :organization_id,
          references(:organizations, type: :string, on_delete: :delete_all),
          null: false

      add :team_id,
          references(:teams, type: :string, on_delete: :delete_all),
          null: false

      add :state_id,
          references(:workflow_states, type: :string, on_delete: :nilify_all)

      add :assignee_id,
          references(:users, type: :string, on_delete: :nilify_all)

      add :parent_id,
          references(:issues, type: :string, on_delete: :nilify_all)

      add :project_id,
          references(:projects, type: :string, on_delete: :nilify_all)

      add :cycle_id,
          references(:cycles, type: :string, on_delete: :nilify_all)

      add :identifier, :string, null: false
      add :number, :integer, null: false
      add :title, :string, null: false
      add :description, :text
      add :priority, :integer
      add :branch_name, :string
      add :url, :string
      add :archived_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:issues, [:organization_id])
    create index(:issues, [:team_id])
    create index(:issues, [:project_id])
    create index(:issues, [:parent_id])
    create unique_index(:issues, [:identifier])

    create table(:issue_relations, primary_key: false) do
      add :id, :string, primary_key: true

      add :issue_id,
          references(:issues, type: :string, on_delete: :delete_all),
          null: false

      add :related_issue_id,
          references(:issues, type: :string, on_delete: :delete_all),
          null: false

      add :type, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:issue_relations, [:issue_id])
    create index(:issue_relations, [:related_issue_id])

    create table(:comments, primary_key: false) do
      add :id, :string, primary_key: true

      add :issue_id,
          references(:issues, type: :string, on_delete: :delete_all),
          null: false

      add :user_id,
          references(:users, type: :string, on_delete: :nilify_all)

      add :body, :text, null: false
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:comments, [:issue_id])

    create table(:issue_labels, primary_key: false) do
      add :id, :string, primary_key: true

      add :issue_id,
          references(:issues, type: :string, on_delete: :delete_all),
          null: false

      add :label_id,
          references(:labels, type: :string, on_delete: :delete_all),
          null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:issue_labels, [:issue_id, :label_id])

    create table(:webhook_deliveries, primary_key: false) do
      add :id, :string, primary_key: true
      add :target_url, :text, null: false
      add :event_type, :string, null: false
      add :action, :string, null: false
      add :payload_json, :text, null: false
      add :signature, :string
      add :status, :string, null: false
      add :response_status, :integer
      add :response_body, :text
      add :error_reason, :text

      timestamps(type: :utc_datetime_usec)
    end
  end
end
