defmodule Sacrum.Repo.Migrations.AddTaskRunHistoryIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  # Serves project run-history pages ordered by updated_at, then id.
  def change do
    create index(:task_runs, [:user_id, :project_id, "updated_at DESC", "id DESC"],
             concurrently: true,
             name: :task_runs_user_project_history_idx
           )
  end
end
