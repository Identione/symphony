defmodule LinearSim.Repo.Migrations.AddColorToWorkflowStates do
  use Ecto.Migration

  # Real Linear workflow states carry a color; the simulator mirrors that so the
  # dashboard can render Linear's exact state colors. Scenarios reseed on reset,
  # so no backfill is needed.
  def change do
    alter table(:workflow_states) do
      add :color, :string
    end
  end
end
