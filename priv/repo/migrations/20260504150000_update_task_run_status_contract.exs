defmodule Sacrum.Repo.Migrations.UpdateTaskRunStatusContract do
  use Ecto.Migration

  def up do
    drop constraint(:task_runs, :task_runs_status_check)

    execute("UPDATE task_runs SET status = 'stopped' WHERE status = 'cancelled'")

    create constraint(:task_runs, :task_runs_status_check,
             check:
               "status IN ('queued', 'executing', 'waiting', 'stopping', 'stopped', 'completed', 'failed')"
           )
  end

  def down do
    drop constraint(:task_runs, :task_runs_status_check)

    execute("UPDATE task_runs SET status = 'cancelled' WHERE status = 'stopped'")
    execute("UPDATE task_runs SET status = 'executing' WHERE status = 'queued'")

    create constraint(:task_runs, :task_runs_status_check,
             check:
               "status IN ('executing', 'waiting', 'stopping', 'completed', 'failed', 'cancelled')"
           )
  end
end
