defmodule Sacrum.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :text
      add :initial_step_id, :binary_id
      add :metadata, :map, default: %{}
      add :auto_advance, :boolean, default: false
      add :display_order, :integer
      add :is_default, :boolean, default: false

      timestamps(type: :utc_datetime_usec)
    end

    alter table(:workflows) do
      add :on_done_workflow_id, references(:workflows, type: :binary_id, on_delete: :nilify_all)
      add :on_reject_workflow_id, references(:workflows, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:workflows, [:project_id])
  end
end
