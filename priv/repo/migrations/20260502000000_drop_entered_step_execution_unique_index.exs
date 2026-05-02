defmodule Sacrum.Repo.Migrations.DropEnteredStepExecutionUniqueIndex do
  use Ecto.Migration

  def up do
    drop index(:step_executions, [:task_id, :workflow_id, :step_id],
           name: "idx_step_executions_entered_unique"
         )
  end

  def down do
    create unique_index(:step_executions, [:task_id, :workflow_id, :step_id],
             where: "status = 'entered'",
             name: "idx_step_executions_entered_unique"
           )
  end
end
