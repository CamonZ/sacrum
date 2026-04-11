defmodule Sacrum.Repo.Migrations.AddOutputSchemaToWorkflowSteps do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      add :output_schema, :map, null: true
    end
  end
end
