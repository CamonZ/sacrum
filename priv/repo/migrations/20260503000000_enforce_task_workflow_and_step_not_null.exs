defmodule Sacrum.Repo.Migrations.EnforceTaskWorkflowAndStepNotNull do
  use Ecto.Migration

  def up do
    # 1. Create a default Backlog workflow for any project missing one.
    execute("""
    INSERT INTO workflows (id, project_id, user_id, name, is_default, inserted_at, updated_at)
    SELECT gen_random_uuid(), p.id, p.user_id, 'Backlog', true, NOW(), NOW()
    FROM projects p
    WHERE NOT EXISTS (
      SELECT 1 FROM workflows w
      WHERE w.project_id = p.id AND w.is_default = true
    )
    """)

    # 2. Create an initial step for any workflow that has none.
    execute("""
    INSERT INTO workflow_steps
      (id, workflow_id, project_id, user_id, name, step_order, is_final, inserted_at, updated_at)
    SELECT gen_random_uuid(), w.id, w.project_id, w.user_id, 'Backlog', 1, false, NOW(), NOW()
    FROM workflows w
    WHERE NOT EXISTS (
      SELECT 1 FROM workflow_steps ws WHERE ws.workflow_id = w.id
    )
    """)

    # 3. Point each workflow's initial_step_id at its first step (by step_order).
    execute("""
    UPDATE workflows w
    SET initial_step_id = (
      SELECT id FROM workflow_steps
      WHERE workflow_id = w.id
      ORDER BY step_order ASC
      LIMIT 1
    )
    WHERE initial_step_id IS NULL
    """)

    # 4. Backfill tasks with NULL workflow_id / current_step_id from the
    #    project's default workflow + its initial step.
    execute("""
    UPDATE tasks t
    SET
      workflow_id = COALESCE(t.workflow_id, w.id),
      current_step_id = COALESCE(t.current_step_id, w.initial_step_id)
    FROM workflows w
    WHERE w.project_id = t.project_id
      AND w.is_default = true
      AND (t.workflow_id IS NULL OR t.current_step_id IS NULL)
    """)

    # 5. Enforce NOT NULL.
    alter table(:tasks) do
      modify :workflow_id, :binary_id, null: false
      modify :current_step_id, :binary_id, null: false
    end
  end

  def down do
    alter table(:tasks) do
      modify :workflow_id, :binary_id, null: true
      modify :current_step_id, :binary_id, null: true
    end
  end
end
