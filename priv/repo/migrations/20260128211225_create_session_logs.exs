defmodule Sacrum.Repo.Migrations.CreateSessionLogs do
  use Ecto.Migration

  def change do
    create table(:session_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :step_execution_id,
          references(:step_executions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :content, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:session_logs, [:step_execution_id])
  end
end
