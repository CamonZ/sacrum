defmodule Sacrum.Repo.Migrations.BackfillParentIdFromTaskHierarchy do
  use Ecto.Migration

  def up do
    execute """
    UPDATE tasks SET parent_id = th.parent_id
    FROM task_hierarchy th WHERE th.child_id = tasks.id
    """
  end

  def down do
    execute """
    INSERT INTO task_hierarchy (id, parent_id, child_id, user_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), t.parent_id, t.id, t.user_id, NOW(), NOW()
    FROM tasks t WHERE t.parent_id IS NOT NULL
    """
  end
end
