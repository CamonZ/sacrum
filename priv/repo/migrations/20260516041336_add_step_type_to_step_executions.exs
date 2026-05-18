defmodule Sacrum.Repo.Migrations.AddStepTypeToStepExecutions do
  use Ecto.Migration

  def change do
    alter table(:step_executions) do
      add :step_type, :string
    end

    execute(
      """
      UPDATE step_executions AS se
      SET step_type = COALESCE(
        (
          SELECT ws.step_type
          FROM workflow_steps AS ws
          WHERE ws.id = se.step_id
          LIMIT 1
        ),
        (
          SELECT ws.step_type
          FROM workflow_steps AS ws
          WHERE ws.workflow_id = se.workflow_id
            AND ws.name = se.step_name
          ORDER BY ws.inserted_at DESC
          LIMIT 1
        ),
        'execute'
      )
      WHERE se.step_type IS NULL
      """,
      """
      UPDATE step_executions
      SET step_type = NULL
      """
    )

    create constraint(:step_executions, :step_executions_step_type_check,
             check:
               "step_type IN ('execute', 'evaluate', 'route', 'wait_children', 'human_input')"
           )

    alter table(:step_executions) do
      modify :step_type, :string, null: false, default: "execute"
    end
  end
end
