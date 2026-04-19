defmodule Sacrum.Repo.Migrations.AddStepIdAndInvalidatedToStepExecutions do
  use Ecto.Migration

  def change do
    # Add step_id FK to step_executions
    alter table(:step_executions) do
      add :step_id, references(:workflow_steps, type: :binary_id, on_delete: :delete_all)
    end

    # Backfill step_id from step_name + workflow_id
    execute(
      fn ->
        Ecto.Adapters.SQL.query!(
          Sacrum.Repo,
          """
          UPDATE step_executions se
          SET step_id = ws.id
          FROM workflow_steps ws
          WHERE se.step_name = ws.name
            AND se.workflow_id = ws.workflow_id
            AND se.step_id IS NULL
          """,
          []
        )
      end,
      fn -> :ok end
    )

    # Invalidate duplicate "entered" records, keeping only the most recent per (task_id, workflow_id, step_id)
    execute(
      fn ->
        Ecto.Adapters.SQL.query!(
          Sacrum.Repo,
          """
          UPDATE step_executions se
          SET status = 'invalidated'
          WHERE se.status = 'entered'
            AND se.id NOT IN (
              SELECT DISTINCT ON (task_id, workflow_id, step_id) id
              FROM step_executions
              WHERE status = 'entered'
              ORDER BY task_id, workflow_id, step_id, inserted_at DESC
            )
          """,
          []
        )
      end,
      fn -> :ok end
    )

    # Create index on step_id
    create index(:step_executions, [:step_id])

    # Create partial unique index for (task_id, workflow_id, step_id) WHERE status='entered'
    create unique_index(:step_executions, [:task_id, :workflow_id, :step_id],
             where: "status = 'entered'",
             name: "idx_step_executions_entered_unique"
           )
  end
end
