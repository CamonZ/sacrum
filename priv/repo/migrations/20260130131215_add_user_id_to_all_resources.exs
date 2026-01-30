defmodule Sacrum.Repo.Migrations.AddUserIdToAllResources do
  use Ecto.Migration

  @tables ~w(tasks workflows workflow_steps step_executions session_logs
             task_sections code_refs task_dependencies task_hierarchy
             step_transitions workflow_transitions)a

  def up do
    # Add nullable user_id column to all resource tables
    for table <- @tables do
      alter table(table) do
        add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
      end
    end

    flush()

    # Backfill in dependency order:
    # Level 1: tables with project_id (direct join to projects)
    execute """
    UPDATE tasks SET user_id = p.user_id
    FROM projects p WHERE tasks.project_id = p.id
    """

    execute """
    UPDATE workflows SET user_id = p.user_id
    FROM projects p WHERE workflows.project_id = p.id
    """

    # Level 2: tables with workflow_id or task_id (join to already-backfilled tables)
    execute """
    UPDATE workflow_steps SET user_id = w.user_id
    FROM workflows w WHERE workflow_steps.workflow_id = w.id
    """

    execute """
    UPDATE step_executions SET user_id = w.user_id
    FROM workflows w WHERE step_executions.workflow_id = w.id
    """

    execute """
    UPDATE task_sections SET user_id = t.user_id
    FROM tasks t WHERE task_sections.task_id = t.id
    """

    execute """
    UPDATE code_refs SET user_id = t.user_id
    FROM tasks t WHERE code_refs.task_id = t.id
    """

    execute """
    UPDATE task_dependencies SET user_id = t.user_id
    FROM tasks t WHERE task_dependencies.task_id = t.id
    """

    execute """
    UPDATE task_hierarchy SET user_id = t.user_id
    FROM tasks t WHERE task_hierarchy.parent_id = t.id
    """

    # Level 3: tables joining to level-2 tables
    execute """
    UPDATE session_logs SET user_id = se.user_id
    FROM step_executions se WHERE session_logs.step_execution_id = se.id
    """

    execute """
    UPDATE step_transitions SET user_id = ws.user_id
    FROM workflow_steps ws WHERE step_transitions.from_step_id = ws.id
    """

    execute """
    UPDATE workflow_transitions SET user_id = w.user_id
    FROM workflows w WHERE workflow_transitions.from_workflow_id = w.id
    """

    flush()

    # Make user_id NOT NULL on all tables
    for table <- @tables do
      alter table(table) do
        modify :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
          null: false,
          from: references(:users, type: :binary_id, on_delete: :delete_all)
      end
    end

    # Create indexes
    for table <- @tables do
      create index(table, [:user_id])
    end
  end

  def down do
    for table <- Enum.reverse(@tables) do
      drop index(table, [:user_id])

      alter table(table) do
        remove :user_id
      end
    end
  end
end
