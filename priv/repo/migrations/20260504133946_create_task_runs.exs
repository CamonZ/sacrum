defmodule Sacrum.Repo.Migrations.CreateTaskRuns do
  use Ecto.Migration

  def change do
    create table(:task_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :status, :string, null: false, default: "executing"
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :stop_requested_at, :utc_datetime_usec

      add :latest_step_execution_id,
          references(:step_executions, type: :binary_id, on_delete: :nilify_all)

      add :failure_kind, :string
      add :failure_reason, :text
      add :failure_context, :map, default: %{}
      add :outcome_kind, :string
      add :outcome_context, :map, default: %{}

      add :parent_task_run_id,
          references(:task_runs, type: :binary_id, on_delete: :delete_all)

      add :root_task_run_id,
          references(:task_runs, type: :binary_id, on_delete: :nothing)

      add :triggered_by_step_execution_id,
          references(:step_executions, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:task_runs, [:task_id, :status])
    create index(:task_runs, [:project_id])
    create index(:task_runs, [:user_id])
    create index(:task_runs, [:root_task_run_id, :inserted_at], name: :task_runs_trace_idx)
    create index(:task_runs, [:parent_task_run_id])
    create index(:task_runs, [:triggered_by_step_execution_id])
    create index(:task_runs, [:latest_step_execution_id])

    create constraint(:task_runs, :task_runs_status_check,
             check:
               "status IN ('executing', 'waiting', 'stopping', 'completed', 'failed', 'cancelled')"
           )

    alter table(:step_executions) do
      add :task_run_id, references(:task_runs, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:step_executions, [:task_run_id, :inserted_at])
  end
end
