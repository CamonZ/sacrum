defmodule Sacrum.Repo.Migrations.AddPipelineSummaryTaskRunIndexes do
  use Ecto.Migration

  def change do
    create index(:tasks, [:user_id, :project_id, :current_step_id, :level],
             where: "archived = false",
             name: :tasks_user_project_current_step_level_active_idx
           )

    create index(:task_runs, [:user_id, :project_id, :status, :task_id],
             name: :task_runs_user_project_status_task_pipeline_idx
           )
  end
end
