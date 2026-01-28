defmodule Sacrum.Repo.Migrations.CreateWorkflowSteps do
  use Ecto.Migration

  def change do
    create table(:workflow_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :goal, :text
      add :agents, {:array, :string}, default: []
      add :skills, {:array, :string}, default: []
      add :agent_config, :map, default: %{}
      add :is_final, :boolean, default: false
      add :step_order, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_steps, [:workflow_id])
  end
end
