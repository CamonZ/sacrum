defmodule Sacrum.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :short_id, :text, null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :title, :string, null: false
      add :description, :text
      add :level, :string
      add :priority, :string
      add :tags, {:array, :string}, default: []

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :nilify_all)

      add :current_step_id,
          references(:workflow_steps, type: :binary_id, on_delete: :nilify_all)

      add :needs_human_review, :boolean, default: false
      add :review_comment, :text

      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tasks, [:short_id])
    create index(:tasks, [:project_id])
    create index(:tasks, [:workflow_id])
  end
end
