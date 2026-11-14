defmodule Sacrum.Repo.Migrations.NullifyDeletedChatCatalogLinks do
  use Ecto.Migration

  @links [
    {"task", "task_id", "tasks"},
    {"execution", "gate_execution_id", "step_executions"},
    {"run", "gate_task_run_id", "task_runs"}
  ]

  def up do
    replace_foreign_keys(:nilify)

    # FK actions bypass the catalog API. Give their row changes a new revision
    # too, so stale writers conflict and realtime clients can order the update.
    execute """
    CREATE FUNCTION chat_catalog_bump_link_revision() RETURNS trigger AS $$
    BEGIN
      IF NEW.revision = OLD.revision THEN
        NEW.revision := OLD.revision + 1;
        NEW.updated_at := timezone('UTC', clock_timestamp());
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER chat_catalog_link_revision
    BEFORE UPDATE ON chat_catalog_entries
    FOR EACH ROW
    WHEN (
      OLD.task_id IS DISTINCT FROM NEW.task_id OR
      OLD.gate_execution_id IS DISTINCT FROM NEW.gate_execution_id OR
      OLD.gate_task_run_id IS DISTINCT FROM NEW.gate_task_run_id
    )
    EXECUTE FUNCTION chat_catalog_bump_link_revision();
    """
  end

  def down do
    execute "DROP TRIGGER chat_catalog_link_revision ON chat_catalog_entries"
    execute "DROP FUNCTION chat_catalog_bump_link_revision()"
    replace_foreign_keys(:restrict)
  end

  defp replace_foreign_keys(action) do
    for {name, column, table} <- @links do
      execute "ALTER TABLE chat_catalog_entries DROP CONSTRAINT chat_catalog_#{name}_scope_fkey"

      # Null only the reference, never the non-null owner/project scope columns.
      on_delete = if action == :nilify, do: " ON DELETE SET NULL (#{column})", else: ""

      execute """
      ALTER TABLE chat_catalog_entries
      ADD CONSTRAINT chat_catalog_#{name}_scope_fkey
      FOREIGN KEY (#{column}, project_id, user_id)
      REFERENCES #{table}(id, project_id, user_id)#{on_delete}
      """
    end
  end
end
