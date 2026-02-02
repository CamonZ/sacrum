defmodule Sacrum.Repo.Migrations.DropTaskHierarchy do
  use Ecto.Migration

  def up do
    drop table(:task_hierarchy)
  end

  def down do
    create table(:task_hierarchy, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :parent_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false

      add :child_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:task_hierarchy, [:child_id])
    create index(:task_hierarchy, [:parent_id])
  end
end
