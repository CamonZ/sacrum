defmodule Sacrum.Repo.Migrations.AddCdcProjectionInfrastructure do
  use Ecto.Migration

  @publication "sacrum_cdc_publication"

  @cdc_tables ~w(
    tasks
    workflows
    workflow_steps
    step_transitions
    workflow_transitions
    step_executions
    task_runs
    session_logs
    task_sections
    task_dependencies
    chat_sessions
    chat_messages
    chat_events
  )

  def up do
    Enum.each(@cdc_tables, fn table ->
      execute("ALTER TABLE IF EXISTS #{table} REPLICA IDENTITY FULL")
    end)

    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '#{@publication}') THEN
        CREATE PUBLICATION #{@publication} FOR TABLE #{Enum.join(@cdc_tables, ", ")};
      END IF;
    END $$;
    """)
  end

  def down do
    execute("DROP PUBLICATION IF EXISTS #{@publication}")

    Enum.each(@cdc_tables, fn table ->
      execute("ALTER TABLE IF EXISTS #{table} REPLICA IDENTITY DEFAULT")
    end)
  end
end
