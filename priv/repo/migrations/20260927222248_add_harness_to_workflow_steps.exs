defmodule Sacrum.Repo.Migrations.AddHarnessToWorkflowSteps do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      add :harness, :string, null: true
    end
  end
end
