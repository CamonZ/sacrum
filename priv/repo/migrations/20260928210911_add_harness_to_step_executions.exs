defmodule Sacrum.Repo.Migrations.AddHarnessToStepExecutions do
  use Ecto.Migration

  def change do
    alter table(:step_executions) do
      add :harness, :string, null: true
    end
  end
end
