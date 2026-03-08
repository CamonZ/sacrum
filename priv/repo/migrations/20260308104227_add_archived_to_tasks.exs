defmodule Sacrum.Repo.Migrations.AddArchivedToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :archived, :boolean, default: false, null: false
    end
  end
end
