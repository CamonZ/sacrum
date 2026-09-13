defmodule Sacrum.Repo.Migrations.AddDaemonsToCdcPublication do
  use Ecto.Migration

  @publication "sacrum_cdc_publication"

  def up do
    execute("ALTER TABLE IF EXISTS daemons REPLICA IDENTITY FULL")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '#{@publication}')
         AND NOT EXISTS (
           SELECT 1
           FROM pg_publication_tables
           WHERE pubname = '#{@publication}'
             AND schemaname = 'public'
             AND tablename = 'daemons'
         ) THEN
        ALTER PUBLICATION #{@publication} ADD TABLE daemons;
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
             AND tablename = 'daemons'
         ) THEN
        ALTER PUBLICATION #{@publication} DROP TABLE daemons;
      END IF;
    END $$;
    """)

    execute("ALTER TABLE IF EXISTS daemons REPLICA IDENTITY DEFAULT")
  end
end
