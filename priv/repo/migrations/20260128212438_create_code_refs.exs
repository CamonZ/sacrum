defmodule Sacrum.Repo.Migrations.CreateCodeRefs do
  use Ecto.Migration

  def change do
    create table(:code_refs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :task_id, references(:tasks, type: :binary_id, on_delete: :delete_all)
      add :section_id, references(:task_sections, type: :binary_id, on_delete: :delete_all)

      add :path, :string, null: false
      add :line_start, :integer
      add :line_end, :integer
      add :name, :string
      add :description, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:code_refs, [:task_id])
    create index(:code_refs, [:section_id])

    create constraint(:code_refs, :exactly_one_parent,
             check:
               "(task_id IS NOT NULL AND section_id IS NULL) OR (task_id IS NULL AND section_id IS NOT NULL)"
           )
  end
end
