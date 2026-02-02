defmodule Sacrum.Repo.Migrations.AddParentIdToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :parent_id, references(:tasks, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:tasks, [:parent_id])
  end
end
