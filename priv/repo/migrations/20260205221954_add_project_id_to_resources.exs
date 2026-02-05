defmodule Sacrum.Repo.Migrations.AddProjectIdToResources do
  use Ecto.Migration

  @tables ~w(workflow_steps step_executions session_logs task_sections
             code_refs task_dependencies step_transitions workflow_transitions)a

  def up do
    # Phase 1: Add nullable project_id column to all resource tables
    for table <- @tables do
      alter table(table) do
        add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all)
      end
    end

    flush()

    # Phase 2: Backfill in dependency order

    # Level 1: tables with direct parent refs (workflow_id or task_id)
    execute """
    UPDATE workflow_steps SET project_id = w.project_id
    FROM workflows w WHERE workflow_steps.workflow_id = w.id
    """

    execute """
    UPDATE workflow_transitions SET project_id = w.project_id
    FROM workflows w WHERE workflow_transitions.from_workflow_id = w.id
    """

    execute """
    UPDATE step_executions SET project_id = t.project_id
    FROM tasks t WHERE step_executions.task_id = t.id
    """

    execute """
    UPDATE task_sections SET project_id = t.project_id
    FROM tasks t WHERE task_sections.task_id = t.id
    """

    execute """
    UPDATE task_dependencies SET project_id = t.project_id
    FROM tasks t WHERE task_dependencies.task_id = t.id
    """

    # code_refs can have task_id OR section_id
    execute """
    UPDATE code_refs SET project_id = t.project_id
    FROM tasks t WHERE code_refs.task_id = t.id
    """

    execute """
    UPDATE code_refs SET project_id = ts.project_id
    FROM task_sections ts WHERE code_refs.section_id = ts.id AND code_refs.project_id IS NULL
    """

    # Level 2: tables joining to level-1 tables
    execute """
    UPDATE session_logs SET project_id = se.project_id
    FROM step_executions se WHERE session_logs.step_execution_id = se.id
    """

    execute """
    UPDATE step_transitions SET project_id = ws.project_id
    FROM workflow_steps ws WHERE step_transitions.from_step_id = ws.id
    """

    flush()

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

      alter table(table) do
        remove :project_id
      end
    end
  end
end
