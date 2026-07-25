defmodule Sacrum.Repo.Migrations.RemoveStepExecutionStepTypeCheckConstraint do
  use Ecto.Migration

  def change do
    drop constraint(:step_executions, :step_executions_step_type_check)
  end
end
