defmodule Sacrum.Repo.Migrations.MigrateEnteredStepExecutionsToInvalidated do
  use Ecto.Migration

  def up do
    execute("UPDATE step_executions SET status = 'invalidated' WHERE status = 'entered'")
  end

  def down do
    execute("UPDATE step_executions SET status = 'entered' WHERE status = 'invalidated'")
  end
end
