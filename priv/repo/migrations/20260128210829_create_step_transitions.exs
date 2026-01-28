defmodule Sacrum.Repo.Migrations.CreateStepTransitions do
  use Ecto.Migration

  def change do
    create table(:step_transitions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :from_step_id, references(:workflow_steps, type: :binary_id, on_delete: :delete_all),
        null: false

      add :to_step_id, references(:workflow_steps, type: :binary_id, on_delete: :delete_all),
        null: false

      add :label, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:step_transitions, [:from_step_id, :to_step_id])
  end
end
