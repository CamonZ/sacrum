defmodule Sacrum.Repo.Migrations.AddFkConstraintsToStepExecutions do
  use Ecto.Migration

  @tables ~w(workflow_steps step_executions session_logs task_sections
             code_refs task_dependencies step_transitions workflow_transitions)a

  def up do
    # Phase 3: Make project_id NOT NULL on all tables
    for table <- @tables do
      alter table(table) do
        modify :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
          null: false,
          from: references(:projects, type: :binary_id, on_delete: :delete_all)
      end
    end

    # Phase 4: Create indexes
    for table <- @tables do
      create index(table, [:project_id])
    end
  end

  def down do
    for table <- Enum.reverse(@tables) do
      drop index(table, [:project_id])
    end
  end
end
