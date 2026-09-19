defmodule Sacrum.Repo.Migrations.EnforceTaskParentScope do
  use Ecto.Migration

  @parent_scope_target_index "tasks_parent_scope_target_index"
  @parent_scope_constraint "tasks_parent_scope_fkey"

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM tasks AS child
        LEFT JOIN tasks AS parent
          ON parent.id = child.parent_id
         AND parent.project_id = child.project_id
         AND parent.user_id = child.user_id
        WHERE child.parent_id IS NOT NULL
          AND parent.id IS NULL
      ) THEN
        RAISE EXCEPTION
          'cannot enforce task parent scope: existing parent references are missing or out of scope';
      END IF;
    END
    $$;
    """

    create unique_index(:tasks, [:id, :project_id, :user_id], name: @parent_scope_target_index)

    flush()

    drop constraint(:tasks, "tasks_parent_id_fkey")

    flush()

    execute """
    ALTER TABLE tasks
    ADD CONSTRAINT #{@parent_scope_constraint}
    FOREIGN KEY (parent_id, project_id, user_id)
    REFERENCES tasks (id, project_id, user_id)
    ON DELETE CASCADE
    """
  end

  def down do
    drop constraint(:tasks, @parent_scope_constraint)
    flush()

    drop unique_index(:tasks, [:id, :project_id, :user_id], name: @parent_scope_target_index)
    flush()

    execute """
    ALTER TABLE tasks
    ADD CONSTRAINT tasks_parent_id_fkey
    FOREIGN KEY (parent_id)
    REFERENCES tasks (id)
    ON DELETE CASCADE
    """
  end
end
