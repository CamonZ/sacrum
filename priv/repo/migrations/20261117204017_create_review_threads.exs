defmodule Sacrum.Repo.Migrations.CreateReviewThreads do
  use Ecto.Migration

  def up do
    create table(:review_threads, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :uuid, primary_key: true
      add :project_id, :uuid, primary_key: true
      add :installation_id, :uuid, primary_key: true
      add :parent_chat_id, :string, size: 200, null: false
      add :path, :text, null: false
      add :side, :text, null: false
      add :home_kind, :text, null: false
      add :tool_use_id, :text
      add :original_commit_id, :text, null: false
      add :original_blob_id, :text, null: false
      add :original_start_line, :integer, null: false
      add :original_line, :integer, null: false
      add :start_line, :integer
      add :line, :integer
      add :status, :text, null: false, default: "open"
      add :outdated_noted, :boolean, null: false, default: false
      add :origin_kind, :text, null: false, default: "local"
      add :origin_ref, :text
      add :deleted, :boolean, null: false, default: false
      add :revision, :bigint, null: false, default: 1
      add :mutation_id, :uuid, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:review_threads, [:user_id, :installation_id, :id])

    create index(:review_threads, [:user_id, :project_id, :installation_id, :parent_chat_id],
             name: :review_threads_parent_scope_index
           )

    execute """
    ALTER TABLE review_threads
      ADD CONSTRAINT review_threads_project_scope_fkey
        FOREIGN KEY (project_id, user_id) REFERENCES projects(id, user_id) ON DELETE CASCADE,
      ADD CONSTRAINT review_threads_installation_scope_fkey
        FOREIGN KEY (installation_id, user_id) REFERENCES chat_installations(id, user_id) ON DELETE CASCADE,
      ADD CONSTRAINT review_threads_parent_scope_fkey
        FOREIGN KEY (parent_chat_id, project_id, installation_id, user_id)
        REFERENCES chat_catalog_entries(chat_id, project_id, installation_id, user_id) ON DELETE CASCADE
    """

    create constraint(:review_threads, :review_threads_side_valid,
             check: "side IN ('LEFT', 'RIGHT')"
           )

    create constraint(:review_threads, :review_threads_home_valid,
             check: """
             home_kind IN ('worktree', 'tool_call') AND
               (home_kind <> 'tool_call' OR (tool_use_id IS NOT NULL AND tool_use_id ~ '[^[:space:]]'))
             """
           )

    create constraint(:review_threads, :review_threads_status_valid,
             check: "status IN ('open', 'outdated')"
           )

    create constraint(:review_threads, :review_threads_origin_valid,
             check: "origin_kind = 'local'"
           )

    create constraint(:review_threads, :review_threads_original_range_valid,
             check: "original_start_line >= 1 AND original_line >= original_start_line"
           )

    create constraint(:review_threads, :review_threads_current_range_valid,
             check: """
             (status = 'open' AND start_line IS NOT NULL AND line IS NOT NULL AND
               start_line >= 1 AND line >= start_line) OR
             (status = 'outdated' AND start_line IS NULL AND line IS NULL)
             """
           )

    create constraint(:review_threads, :review_threads_path_valid,
             check: """
             char_length(path) BETWEEN 1 AND 4096 AND left(path, 1) <> '/' AND
               path !~ '(^|/)[.][.](/|$)'
             """
           )

    create constraint(:review_threads, :review_threads_object_ids_valid,
             check: """
             original_commit_id ~ '^([0-9a-f]{40}|[0-9a-f]{64})$' AND
               original_blob_id ~ '^([0-9a-f]{40}|[0-9a-f]{64})$'
             """
           )

    create constraint(:review_threads, :review_threads_revision_positive, check: "revision > 0")

    execute """
    CREATE FUNCTION review_threads_guard_update() RETURNS trigger AS $$
    BEGIN
      IF OLD.deleted THEN
        RAISE check_violation USING CONSTRAINT = 'review_threads_tombstone_terminal',
          MESSAGE = 'review thread is tombstoned';
      END IF;

      IF ROW(NEW.id, NEW.user_id, NEW.project_id, NEW.installation_id, NEW.parent_chat_id,
             NEW.path, NEW.side, NEW.home_kind, NEW.tool_use_id, NEW.original_commit_id,
             NEW.original_blob_id, NEW.original_start_line, NEW.original_line)
         IS DISTINCT FROM
         ROW(OLD.id, OLD.user_id, OLD.project_id, OLD.installation_id, OLD.parent_chat_id,
             OLD.path, OLD.side, OLD.home_kind, OLD.tool_use_id, OLD.original_commit_id,
             OLD.original_blob_id, OLD.original_start_line, OLD.original_line) THEN
        RAISE check_violation USING CONSTRAINT = 'review_threads_anchor_immutable',
          MESSAGE = 'review thread scope and original anchor are immutable';
      END IF;

      NEW.revision := OLD.revision + 1;
      IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
        NEW.updated_at := timezone('UTC', clock_timestamp());
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER review_threads_guard_update
    BEFORE UPDATE ON review_threads
    FOR EACH ROW EXECUTE FUNCTION review_threads_guard_update();
    """

    execute "ALTER TABLE review_threads REPLICA IDENTITY FULL"

    execute """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'sacrum_cdc_publication') THEN
        ALTER PUBLICATION sacrum_cdc_publication ADD TABLE review_threads;
      END IF;
    END $$;
    """
  end

  def down do
    drop table(:review_threads)
    execute "DROP FUNCTION review_threads_guard_update()"
  end
end
