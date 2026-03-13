defmodule Sacrum.Repo.Migrations.AddTaskIdFkToStepExecutions do
  use Ecto.Migration

  def change do
    alter table(:step_executions) do
      modify :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all),
        from: :binary_id
    end
  end
end
