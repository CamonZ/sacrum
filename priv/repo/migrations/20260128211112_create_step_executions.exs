defmodule Sacrum.Repo.Migrations.CreateStepExecutions do
  use Ecto.Migration

  def change do
    create table(:step_executions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      # task_id FK will be added when the tasks table is created
      add :task_id, :binary_id
      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :nilify_all)
      add :step_name, :string, null: false
      add :status, :string
      add :context, :map, default: %{}
      add :prompt, :text
      add :output, :text
      add :transition_result, :string
      add :model, :string
      add :model_provider, :string
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cost, :decimal
      add :duration_ms, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create index(:step_executions, [:task_id])
    create index(:step_executions, [:workflow_id])
  end
end
