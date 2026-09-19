defmodule Sacrum.Repo.Migrations.EnforceProjectOwnershipCompositeForeignKeys do
  use Ecto.Migration

  @project_scope_target_index "projects_project_scope_target_index"
  @task_project_scope_constraint "tasks_project_scope_fkey"
  @workflow_project_scope_constraint "workflows_project_scope_fkey"

  def up do
    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM tasks AS task
        LEFT JOIN projects AS project
          ON project.id = task.project_id
         AND project.user_id = task.user_id
        WHERE project.id IS NULL
      ) THEN
        RAISE EXCEPTION
          'cannot enforce task project scope: existing project references are missing or out of scope';
      END IF;

      IF EXISTS (
        SELECT 1
        FROM workflows AS workflow
        LEFT JOIN projects AS project
          ON project.id = workflow.project_id
         AND project.user_id = workflow.user_id
        WHERE project.id IS NULL
      ) THEN
        RAISE EXCEPTION
          'cannot enforce workflow project scope: existing project references are missing or out of scope';
      END IF;
    END
    $$;
    """

    create unique_index(:projects, [:id, :user_id], name: @project_scope_target_index)
    flush()

    drop constraint(:tasks, "tasks_project_id_fkey")
    drop constraint(:workflows, "workflows_project_id_fkey")
    flush()

    execute """
    ALTER TABLE tasks
    ADD CONSTRAINT #{@task_project_scope_constraint}
    FOREIGN KEY (project_id, user_id)
    REFERENCES projects (id, user_id)
    ON DELETE CASCADE
    """

    execute """
    ALTER TABLE workflows
    ADD CONSTRAINT #{@workflow_project_scope_constraint}
    FOREIGN KEY (project_id, user_id)
    REFERENCES projects (id, user_id)
    ON DELETE CASCADE
    """
  end

  def down do
    drop constraint(:tasks, @task_project_scope_constraint)
    drop constraint(:workflows, @workflow_project_scope_constraint)
    flush()

    drop unique_index(:projects, [:id, :user_id], name: @project_scope_target_index)
    flush()

    execute """
    ALTER TABLE tasks
    ADD CONSTRAINT tasks_project_id_fkey
    FOREIGN KEY (project_id)
    REFERENCES projects (id)
    ON DELETE CASCADE
    """

    execute """
    ALTER TABLE workflows
    ADD CONSTRAINT workflows_project_id_fkey
    FOREIGN KEY (project_id)
    REFERENCES projects (id)
    ON DELETE CASCADE
    """
  end
end
