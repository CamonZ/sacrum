defmodule Sacrum.Repo.Migrations.CreateTaskDependencies do
  use Ecto.Migration

  def change do
    create table(:task_dependencies, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false

      add :depends_on_id, references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:task_dependencies, [:task_id, :depends_on_id])
    create constraint(:task_dependencies, :no_self_dependency, check: "task_id != depends_on_id")
  end
end
