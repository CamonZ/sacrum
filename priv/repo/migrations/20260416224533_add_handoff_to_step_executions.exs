defmodule Sacrum.Repo.Migrations.AddHandoffToStepExecutions do
  use Ecto.Migration

  def change do
    alter table(:step_executions) do
      add :handoff, :map
    end
  end
end
