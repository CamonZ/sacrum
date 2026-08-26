defmodule Sacrum.Repo.Migrations.AddPersistenceOptionsToWorkflowSteps do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      add :persistence_options, :map, null: true
    end
  end
end
