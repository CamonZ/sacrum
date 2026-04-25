defmodule Sacrum.Repo.Migrations.AddPipelineSummaryIndexes do
  use Ecto.Migration

  def change do
    create index(:tasks, [:project_id, :current_step_id])

    create index(:step_executions, [:step_id],
             where: "status = 'started'",
             name: :step_executions_started_by_step_idx
           )
  end
end
