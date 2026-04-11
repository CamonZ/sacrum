defmodule Sacrum.Repo.Migrations.AddStepTypeToWorkflowSteps do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      add :step_type, :string, null: false, default: "execute"
    end
  end
end
