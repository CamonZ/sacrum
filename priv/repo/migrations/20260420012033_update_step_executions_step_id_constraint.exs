defmodule Sacrum.Repo.Migrations.UpdateStepExecutionsStepIdConstraint do
  use Ecto.Migration

  def up do
    # Drop the old RESTRICT constraint and add the new DELETE ALL constraint
    execute("ALTER TABLE step_executions DROP CONSTRAINT step_executions_step_id_fkey")

    execute(
      "ALTER TABLE step_executions ADD CONSTRAINT step_executions_step_id_fkey FOREIGN KEY (step_id) REFERENCES workflow_steps(id) ON DELETE CASCADE"
    )
  end

  def down do
    # Reverse: drop the new constraint and add back the old one
    execute("ALTER TABLE step_executions DROP CONSTRAINT step_executions_step_id_fkey")

    execute(
      "ALTER TABLE step_executions ADD CONSTRAINT step_executions_step_id_fkey FOREIGN KEY (step_id) REFERENCES workflow_steps(id) ON DELETE RESTRICT"
    )
  end
end
