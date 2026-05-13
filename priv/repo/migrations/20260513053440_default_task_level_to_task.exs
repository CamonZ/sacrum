defmodule Sacrum.Repo.Migrations.DefaultTaskLevelToTask do
  use Ecto.Migration

  def up do
    execute("UPDATE tasks SET level = 'task' WHERE level IS NULL")

    alter table(:tasks) do
      modify :level, :string, default: "task"
    end
  end

  def down do
    alter table(:tasks) do
      modify :level, :string, default: nil
    end
  end
end
