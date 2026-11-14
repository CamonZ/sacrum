defmodule Sacrum.Repo.Migrations.CreateMachineChatCatalog do
  use Ecto.Migration

  def up do
    create table(:chat_installations, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :user_id, references(:users, type: :uuid, on_delete: :delete_all),
        null: false,
        primary_key: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:chat_installations, [:id, :user_id])

    create unique_index(:step_executions, [:id, :project_id, :user_id],
             name: :chat_execution_scope_index
           )

    create unique_index(:task_runs, [:id, :project_id, :user_id], name: :chat_run_scope_index)

    create table(:chat_catalog_entries, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :uuid, null: false
      add :project_id, :uuid, null: false
      add :installation_id, :uuid, null: false
      add :chat_id, :string, size: 200, null: false
      add :task_id, :uuid
      add :parent_chat_id, :string, size: 200
      add :gate_execution_id, :uuid
      add :gate_task_run_id, :uuid
      add :metadata, :map, null: false, default: %{}
      add :classifications, {:array, :map}, null: false, default: []
      add :deleted, :boolean, null: false, default: false
      add :revision, :bigint, null: false, default: 1
      add :mutation_id, :uuid, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:chat_catalog_entries, [:user_id, :installation_id, :chat_id])

    create unique_index(
             :chat_catalog_entries,
             [:chat_id, :project_id, :installation_id, :user_id],
             name: :chat_catalog_parent_scope_index
           )

    create index(:chat_catalog_entries, [:user_id, :project_id, :installation_id, :chat_id])

    execute "ALTER TABLE chat_catalog_entries ADD CONSTRAINT chat_catalog_project_scope_fkey FOREIGN KEY (project_id,user_id) REFERENCES projects(id,user_id) ON DELETE CASCADE"

    execute "ALTER TABLE chat_catalog_entries ADD CONSTRAINT chat_catalog_installation_scope_fkey FOREIGN KEY (installation_id,user_id) REFERENCES chat_installations(id,user_id) ON DELETE CASCADE"

    execute "ALTER TABLE chat_catalog_entries ADD CONSTRAINT chat_catalog_task_scope_fkey FOREIGN KEY (task_id,project_id,user_id) REFERENCES tasks(id,project_id,user_id)"

    execute "ALTER TABLE chat_catalog_entries ADD CONSTRAINT chat_catalog_parent_scope_fkey FOREIGN KEY (parent_chat_id,project_id,installation_id,user_id) REFERENCES chat_catalog_entries(chat_id,project_id,installation_id,user_id)"

    execute "ALTER TABLE chat_catalog_entries ADD CONSTRAINT chat_catalog_execution_scope_fkey FOREIGN KEY (gate_execution_id,project_id,user_id) REFERENCES step_executions(id,project_id,user_id)"

    execute "ALTER TABLE chat_catalog_entries ADD CONSTRAINT chat_catalog_run_scope_fkey FOREIGN KEY (gate_task_run_id,project_id,user_id) REFERENCES task_runs(id,project_id,user_id)"

    create constraint(:chat_catalog_entries, :chat_catalog_revision_positive,
             check: "revision > 0"
           )

    execute "ALTER TABLE chat_catalog_entries REPLICA IDENTITY FULL"

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'sacrum_cdc_publication') THEN
        ALTER PUBLICATION sacrum_cdc_publication ADD TABLE chat_catalog_entries;
      END IF;
    END $$;
    """
  end

  def down do
    drop table(:chat_catalog_entries)
    drop table(:chat_installations)
    drop index(:step_executions, [:id, :project_id, :user_id], name: :chat_execution_scope_index)
    drop index(:task_runs, [:id, :project_id, :user_id], name: :chat_run_scope_index)
  end
end
