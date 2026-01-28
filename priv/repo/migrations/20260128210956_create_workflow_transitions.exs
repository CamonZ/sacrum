defmodule Sacrum.Repo.Migrations.CreateWorkflowTransitions do
  use Ecto.Migration

  def change do
    create table(:workflow_transitions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :from_workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :to_workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :label, :string

      add :target_step_id, references(:workflow_steps, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workflow_transitions, [:from_workflow_id, :to_workflow_id])
  end
end
