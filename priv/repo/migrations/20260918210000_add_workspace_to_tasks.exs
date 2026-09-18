defmodule Sacrum.Repo.Migrations.AddWorkspaceToTasks do
  use Ecto.Migration

  @workspace_daemon_fk "tasks_workspace_daemon_id_fkey"
  @workspace_daemon_index "tasks_workspace_daemon_id_index"

  def up do
    alter table(:tasks) do
      add :workspace, :map
    end

    execute("""
    UPDATE tasks
    SET workspace = jsonb_build_object('worktree_path', worktree)
    WHERE worktree IS NOT NULL
    """)

    alter table(:tasks) do
      remove :worktree
    end

    execute("""
    ALTER TABLE tasks
    ADD COLUMN workspace_daemon_id uuid
    GENERATED ALWAYS AS ((workspace ->> 'daemon_id')::uuid) STORED
    """)

    execute("""
    ALTER TABLE tasks
    ADD CONSTRAINT #{@workspace_daemon_fk}
    FOREIGN KEY (workspace_daemon_id)
    REFERENCES daemons(id)
    ON DELETE RESTRICT
    """)

    create index(:tasks, [:workspace_daemon_id], name: @workspace_daemon_index)

    publish_generated_workspace_column()
  end

  def down do
    unpublish_generated_workspace_column()

    drop index(:tasks, [:workspace_daemon_id], name: @workspace_daemon_index)

    execute("ALTER TABLE tasks DROP CONSTRAINT #{@workspace_daemon_fk}")
    execute("ALTER TABLE tasks DROP COLUMN workspace_daemon_id")

    alter table(:tasks) do
      add :worktree, :string
    end

    execute("""
    UPDATE tasks
    SET worktree = workspace ->> 'worktree_path'
    WHERE workspace IS NOT NULL
    """)

    alter table(:tasks) do
      remove :workspace
    end
  end

  defp publish_generated_workspace_column do
    execute("""
    DO $$
    BEGIN
      IF current_setting('server_version_num')::integer >= 180000 THEN
        IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'sacrum_cdc_publication') THEN
          EXECUTE 'ALTER PUBLICATION sacrum_cdc_publication SET (publish_generated_columns = ''stored'')';
        END IF;
      ELSE
        ALTER TABLE tasks REPLICA IDENTITY USING INDEX tasks_pkey;
      END IF;
    END $$;
    """)
  end

  defp unpublish_generated_workspace_column do
    execute("""
    DO $$
    BEGIN
      IF current_setting('server_version_num')::integer >= 180000 THEN
        IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'sacrum_cdc_publication') THEN
          EXECUTE 'ALTER PUBLICATION sacrum_cdc_publication SET (publish_generated_columns = ''none'')';
        END IF;
      ELSE
        ALTER TABLE tasks REPLICA IDENTITY FULL;
      END IF;
    END $$;
    """)
  end
end
