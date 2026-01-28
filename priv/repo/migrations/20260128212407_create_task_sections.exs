defmodule Sacrum.Repo.Migrations.CreateTaskSections do
  use Ecto.Migration

  def change do
    create table(:task_sections, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all), null: false

      add :section_type, :string, null: false
      add :content, :text, null: false
      add :section_order, :integer
      add :done, :boolean, default: false
      add :done_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:task_sections, [:task_id])
  end
end
