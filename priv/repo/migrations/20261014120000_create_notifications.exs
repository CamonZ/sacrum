defmodule Sacrum.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  @publication "sacrum_cdc_publication"
  @project_scope_constraint "notifications_project_scope_fkey"

  def up do
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :project_id, :binary_id, null: false

      add :message, :text, null: false
      add :severity, :string, null: false
      add :read_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec, null: false
    end

    # Same ownership rule as tasks and workflows: the project must belong to
    # the notification's user.
    execute """
    ALTER TABLE notifications
    ADD CONSTRAINT #{@project_scope_constraint}
    FOREIGN KEY (project_id, user_id)
    REFERENCES projects (id, user_id)
    ON DELETE CASCADE
    """

    create index(:notifications, [:user_id, :project_id, :inserted_at, :id])

    create constraint(:notifications, :notifications_severity_check,
             check: "severity IN ('info', 'success', 'warning', 'error')"
           )

    execute("ALTER TABLE notifications REPLICA IDENTITY FULL")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '#{@publication}')
         AND NOT EXISTS (
           SELECT 1
           FROM pg_publication_tables
           WHERE pubname = '#{@publication}'
             AND schemaname = 'public'
             AND tablename = 'notifications'
         ) THEN
        ALTER PUBLICATION #{@publication} ADD TABLE notifications;
      END IF;
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '#{@publication}')
         AND EXISTS (
           SELECT 1
           FROM pg_publication_tables
           WHERE pubname = '#{@publication}'
             AND schemaname = 'public'
             AND tablename = 'notifications'
         ) THEN
        ALTER PUBLICATION #{@publication} DROP TABLE notifications;
      END IF;
    END $$;
    """)

    drop table(:notifications)
  end
end
