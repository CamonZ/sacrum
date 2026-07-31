defmodule Sacrum.Repo.Migrations.AddArtifactsToCdcPublication do
  use Ecto.Migration

  @publication "sacrum_cdc_publication"
  @tables ~w(artifacts artifact_links)

  def up do
    Enum.each(@tables, fn table ->
      execute("ALTER TABLE IF EXISTS #{table} REPLICA IDENTITY FULL")
    end)

    Enum.each(@tables, &add_table_to_publication/1)
  end

  def down do
    Enum.each(@tables, &remove_table_from_publication/1)

    Enum.each(@tables, fn table ->
      execute("ALTER TABLE IF EXISTS #{table} REPLICA IDENTITY DEFAULT")
    end)
  end

  defp add_table_to_publication(table) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '#{@publication}')
         AND NOT EXISTS (
           SELECT 1
           FROM pg_publication_tables
           WHERE pubname = '#{@publication}'
             AND schemaname = 'public'
             AND tablename = '#{table}'
         ) THEN
        ALTER PUBLICATION #{@publication} ADD TABLE #{table};
      END IF;
    END $$;
    """)
  end

  defp remove_table_from_publication(table) do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '#{@publication}')
         AND EXISTS (
           SELECT 1
           FROM pg_publication_tables
           WHERE pubname = '#{@publication}'
             AND schemaname = 'public'
             AND tablename = '#{table}'
         ) THEN
        ALTER PUBLICATION #{@publication} DROP TABLE #{table};
      END IF;
    END $$;
    """)
  end
end
