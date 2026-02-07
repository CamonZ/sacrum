defmodule Sacrum.Repo.Migrations.ChangeParentIdCascadeDelete do
  use Ecto.Migration

  def change do
    # Drop the old foreign key constraint that uses nilify_all
    drop constraint(:tasks, "tasks_parent_id_fkey")

    # Add new foreign key with delete_all (cascade delete)
    alter table(:tasks) do
      modify :parent_id, references(:tasks, type: :binary_id, on_delete: :delete_all)
    end
  end
end
