defmodule Sacrum.Repo.Migrations.AddTaskIdentifiers do
  @moduledoc """
  Adds human-readable, project-scoped task identifiers such as `VTB-1`.

  * `projects.key_prefix` is the identifier prefix. It starts unset, for
    existing and new projects alike; numbering is enabled by setting it.
  * `projects.last_task_number` is the per user/project allocation counter. It
    never decreases, so deleted numbers are never reused.
  * `tasks.number` is allocated by a trigger from one sequence shared by every
    task level, but only in projects with a prefix; tasks in other projects stay
    unnumbered. Ordinary updates keep the number; moving a task to another
    project allocates a fresh number from the destination project.
  * Setting a project's prefix for the first time numbers its existing tasks by
    `inserted_at`, then `id`, and the counter continues after them.
  * A prefix becomes immutable once its project has issued any number.
  """

  use Ecto.Migration

  def up do
    alter table(:projects) do
      add :key_prefix, :string, size: 10
      add :last_task_number, :integer, null: false, default: 0
    end

    alter table(:tasks) do
      add :number, :integer
    end

    create constraint(:projects, :projects_key_prefix_format,
             check: "key_prefix ~ '^[A-Z][A-Z0-9]{0,9}$'"
           )

    create constraint(:projects, :projects_last_task_number_non_negative,
             check: "last_task_number >= 0"
           )

    create constraint(:tasks, :tasks_number_positive, check: "number > 0")

    create unique_index(:tasks, [:user_id, :project_id, :number],
             name: :tasks_user_id_project_id_number_index
           )

    execute """
    CREATE FUNCTION projects_guard_task_keys() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF TG_OP = 'INSERT' THEN
        NEW.last_task_number := 0;
        RETURN NEW;
      END IF;

      IF NEW.last_task_number < OLD.last_task_number THEN
        RAISE EXCEPTION 'project task number counter cannot decrease'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'projects_last_task_number_monotonic';
      END IF;

      IF NEW.key_prefix IS DISTINCT FROM OLD.key_prefix
         AND OLD.key_prefix IS NOT NULL
         AND OLD.last_task_number > 0 THEN
        RAISE EXCEPTION 'project key prefix cannot change after task identifiers are issued'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'projects_key_prefix_immutable';
      END IF;

      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER projects_guard_task_keys
    BEFORE INSERT OR UPDATE OF key_prefix, last_task_number ON projects
    FOR EACH ROW EXECUTE FUNCTION projects_guard_task_keys()
    """

    # Enabling numbering touches each unnumbered task in creation order; the
    # task trigger allocates the next number for every one of them.
    execute """
    CREATE FUNCTION projects_number_existing_tasks() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      task record;
    BEGIN
      IF OLD.key_prefix IS NULL AND NEW.key_prefix IS NOT NULL THEN
        FOR task IN
          SELECT id FROM tasks
          WHERE project_id = NEW.id AND user_id = NEW.user_id AND number IS NULL
          ORDER BY inserted_at, id
        LOOP
          UPDATE tasks SET number = NULL WHERE id = task.id;
        END LOOP;
      END IF;

      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER projects_number_existing_tasks
    AFTER UPDATE OF key_prefix ON projects
    FOR EACH ROW EXECUTE FUNCTION projects_number_existing_tasks()
    """

    execute """
    CREATE FUNCTION tasks_assign_number() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      enabled boolean;
    BEGIN
      IF TG_OP = 'UPDATE'
         AND NEW.project_id IS NOT DISTINCT FROM OLD.project_id
         AND NEW.user_id IS NOT DISTINCT FROM OLD.user_id
         AND OLD.number IS NOT NULL THEN
        NEW.number := OLD.number;
        RETURN NEW;
      END IF;

      IF NEW.project_id IS NULL OR NEW.user_id IS NULL THEN
        NEW.number := NULL;
        RETURN NEW;
      END IF;

      -- Lock the project row even when numbering is disabled, so enabling it
      -- waits for in-flight inserts and then numbers them too.
      SELECT key_prefix IS NOT NULL INTO enabled
      FROM projects
      WHERE id = NEW.project_id AND user_id = NEW.user_id
      FOR NO KEY UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'project % is not owned by the task owner', NEW.project_id
          USING ERRCODE = 'foreign_key_violation',
                CONSTRAINT = 'tasks_project_scope_fkey';
      END IF;

      IF NOT enabled THEN
        NEW.number := NULL;
        RETURN NEW;
      END IF;

      UPDATE projects
      SET last_task_number = last_task_number + 1
      WHERE id = NEW.project_id AND user_id = NEW.user_id
      RETURNING last_task_number INTO NEW.number;

      RETURN NEW;
    END
    $$
    """

    execute """
    CREATE TRIGGER tasks_assign_number
    BEFORE INSERT OR UPDATE OF project_id, user_id, number ON tasks
    FOR EACH ROW EXECUTE FUNCTION tasks_assign_number()
    """
  end

  def down do
    execute "DROP TRIGGER tasks_assign_number ON tasks"
    execute "DROP FUNCTION tasks_assign_number()"
    execute "DROP TRIGGER projects_number_existing_tasks ON projects"
    execute "DROP FUNCTION projects_number_existing_tasks()"
    execute "DROP TRIGGER projects_guard_task_keys ON projects"
    execute "DROP FUNCTION projects_guard_task_keys()"

    drop index(:tasks, [:user_id, :project_id, :number],
           name: :tasks_user_id_project_id_number_index
         )

    alter table(:tasks) do
      remove :number
    end

    alter table(:projects) do
      remove :key_prefix
      remove :last_task_number
    end
  end
end
