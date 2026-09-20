defmodule Sacrum.Repo.Migrations.RestoreTasksReplicaIdentity do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE tasks REPLICA IDENTITY FULL")
  end

  def down do
    execute("ALTER TABLE tasks REPLICA IDENTITY USING INDEX tasks_pkey")
  end
end
