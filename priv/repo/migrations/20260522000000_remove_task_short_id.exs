defmodule Sacrum.Repo.Migrations.RemoveTaskShortId do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:tasks, [:short_id])

    alter table(:tasks) do
      remove :short_id
    end
  end

  def down do
    raise Ecto.MigrationError,
          "cannot restore generated task short_id values after dropping tasks.short_id"
  end
end
