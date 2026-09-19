defmodule Sacrum.Repo.Migrations.EnforceTaskSectionAndDependencyScope do
  use Ecto.Migration

  @task_section_scope_constraint "task_sections_task_scope_fkey"
  @dependency_task_scope_constraint "task_dependencies_task_scope_fkey"
  @dependency_depends_on_scope_constraint "task_dependencies_depends_on_scope_fkey"

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM task_sections AS section
        LEFT JOIN tasks AS task
          ON task.id = section.task_id
         AND task.project_id = section.project_id
         AND task.user_id = section.user_id
        WHERE task.id IS NULL
      ) THEN
        RAISE EXCEPTION
          'cannot enforce task section scope: existing task references are missing or out of scope';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM task_dependencies AS dependency
        LEFT JOIN tasks AS task
          ON task.id = dependency.task_id
         AND task.project_id = dependency.project_id
         AND task.user_id = dependency.user_id
        WHERE task.id IS NULL
      ) THEN
        RAISE EXCEPTION
          'cannot enforce dependency task scope: existing task references are missing or out of scope';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM task_dependencies AS dependency
        LEFT JOIN tasks AS task
          ON task.id = dependency.depends_on_id
         AND task.project_id = dependency.project_id
         AND task.user_id = dependency.user_id
        WHERE task.id IS NULL
      ) THEN
        RAISE EXCEPTION
          'cannot enforce dependency target scope: existing task references are missing or out of scope';
      END IF;
    END
    $$;
    """

    drop constraint(:task_sections, "task_sections_task_id_fkey")
    drop constraint(:task_dependencies, "task_dependencies_task_id_fkey")
    drop constraint(:task_dependencies, "task_dependencies_depends_on_id_fkey")

    flush()

    execute """
    ALTER TABLE task_sections
    ADD CONSTRAINT #{@task_section_scope_constraint}
    FOREIGN KEY (task_id, project_id, user_id)
    REFERENCES tasks (id, project_id, user_id)
    ON DELETE CASCADE
    """

    execute """
    ALTER TABLE task_dependencies
    ADD CONSTRAINT #{@dependency_task_scope_constraint}
    FOREIGN KEY (task_id, project_id, user_id)
    REFERENCES tasks (id, project_id, user_id)
    ON DELETE CASCADE
    """

    execute """
    ALTER TABLE task_dependencies
    ADD CONSTRAINT #{@dependency_depends_on_scope_constraint}
    FOREIGN KEY (depends_on_id, project_id, user_id)
    REFERENCES tasks (id, project_id, user_id)
    ON DELETE CASCADE
    """
  end

  def down do
    drop constraint(:task_sections, @task_section_scope_constraint)
    drop constraint(:task_dependencies, @dependency_task_scope_constraint)
    drop constraint(:task_dependencies, @dependency_depends_on_scope_constraint)

    flush()

    execute """
    ALTER TABLE task_sections
    ADD CONSTRAINT task_sections_task_id_fkey
    FOREIGN KEY (task_id)
    REFERENCES tasks (id)
    ON DELETE CASCADE
    """

    execute """
    ALTER TABLE task_dependencies
    ADD CONSTRAINT task_dependencies_task_id_fkey
    FOREIGN KEY (task_id)
    REFERENCES tasks (id)
    ON DELETE CASCADE
    """

    execute """
    ALTER TABLE task_dependencies
    ADD CONSTRAINT task_dependencies_depends_on_id_fkey
    FOREIGN KEY (depends_on_id)
    REFERENCES tasks (id)
    ON DELETE CASCADE
    """
  end
end
