defmodule Sacrum.Repo.Migrations.AddSessionBindingToStepExecutions do
  use Ecto.Migration

  def change do
    alter table(:step_executions) do
      add :session_name, :string
      add :resume_session_id, :string
      add :native_session_id, :string
    end

    create index(:step_executions, [:task_run_id, :session_name, :inserted_at],
             where: "session_name IS NOT NULL"
           )
  end
end
