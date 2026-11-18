defmodule Sacrum.Repo.Migrations.CascadeChatTombstones do
  use Ecto.Migration

  def up do
    execute """
    CREATE FUNCTION tombstone_chat_review_threads() RETURNS trigger AS $$
    BEGIN
      UPDATE review_threads
      SET deleted = true
      WHERE user_id = NEW.user_id AND project_id = NEW.project_id
        AND installation_id = NEW.installation_id AND parent_chat_id = NEW.chat_id
        AND NOT deleted;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER chat_catalog_cascade_tombstone
    AFTER INSERT OR UPDATE OF deleted ON chat_catalog_entries
    FOR EACH ROW WHEN (NEW.deleted) EXECUTE FUNCTION tombstone_chat_review_threads();
    """

    execute """
    CREATE FUNCTION tombstone_review_thread_discussions() RETURNS trigger AS $$
    BEGIN
      UPDATE chat_catalog_entries
      SET deleted = true,
          revision = revision + 1,
          mutation_id = gen_random_uuid(),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE user_id = NEW.user_id AND project_id = NEW.project_id
        AND installation_id = NEW.installation_id AND review_thread_id = NEW.id
        AND NOT deleted;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER review_threads_cascade_tombstone
    AFTER INSERT OR UPDATE OF deleted ON review_threads
    FOR EACH ROW WHEN (NEW.deleted) EXECUTE FUNCTION tombstone_review_thread_discussions();
    """

    # The shared row lock makes a live child write wait for a concurrent tombstone.
    # If the child writes first, the tombstone waits and then includes it in the cascade.
    execute """
    CREATE FUNCTION guard_review_thread_parent_liveness() RETURNS trigger AS $$
    DECLARE
      parent_deleted boolean;
    BEGIN
      IF NOT NEW.deleted AND NEW.parent_chat_id IS NOT NULL THEN
        SELECT deleted INTO parent_deleted FROM chat_catalog_entries
        WHERE user_id = NEW.user_id AND project_id = NEW.project_id
          AND installation_id = NEW.installation_id AND chat_id = NEW.parent_chat_id
        FOR SHARE;

        IF NOT FOUND OR parent_deleted THEN
          RAISE foreign_key_violation USING CONSTRAINT = 'review_threads_parent_scope_fkey',
            MESSAGE = 'parent chat is missing or tombstoned';
        END IF;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER review_threads_guard_parent_liveness
    BEFORE INSERT ON review_threads
    FOR EACH ROW EXECUTE FUNCTION guard_review_thread_parent_liveness();
    """

    execute """
    CREATE FUNCTION guard_discussion_thread_liveness() RETURNS trigger AS $$
    DECLARE
      thread_deleted boolean;
    BEGIN
      IF NEW.deleted OR NEW.review_thread_id IS NULL OR NEW.parent_chat_id IS NULL THEN
        RETURN NEW;
      END IF;

      -- An unchanged live reference is protected by the cascading row update.
      IF TG_OP = 'UPDATE' AND NOT OLD.deleted AND
        ROW(NEW.user_id, NEW.project_id, NEW.installation_id, NEW.parent_chat_id, NEW.review_thread_id)
        IS NOT DISTINCT FROM
        ROW(OLD.user_id, OLD.project_id, OLD.installation_id, OLD.parent_chat_id, OLD.review_thread_id)
      THEN
        RETURN NEW;
      END IF;

      SELECT deleted INTO thread_deleted FROM review_threads
      WHERE user_id = NEW.user_id AND project_id = NEW.project_id
        AND installation_id = NEW.installation_id AND id = NEW.review_thread_id
        AND parent_chat_id = NEW.parent_chat_id
      FOR SHARE;

      IF NOT FOUND OR thread_deleted THEN
        RAISE foreign_key_violation USING CONSTRAINT = 'chat_catalog_review_thread_scope_fkey',
          MESSAGE = 'review thread is missing or tombstoned';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE TRIGGER chat_catalog_guard_discussion_thread_liveness
    BEFORE INSERT OR UPDATE OF deleted, user_id, project_id, installation_id, parent_chat_id, review_thread_id
    ON chat_catalog_entries
    FOR EACH ROW EXECUTE FUNCTION guard_discussion_thread_liveness();
    """

    # Repair edges already pointing at tombstones when this migration is applied.
    # Review-thread revisions are advanced by the existing update trigger.
    execute """
    UPDATE review_threads AS thread
    SET deleted = true
    FROM chat_catalog_entries AS chat
    WHERE chat.user_id = thread.user_id AND chat.project_id = thread.project_id
      AND chat.installation_id = thread.installation_id AND chat.chat_id = thread.parent_chat_id
      AND chat.deleted AND NOT thread.deleted
    """

    execute """
    UPDATE chat_catalog_entries AS discussion
    SET deleted = true,
        revision = discussion.revision + 1,
        mutation_id = gen_random_uuid(),
        updated_at = timezone('UTC', clock_timestamp())
    FROM review_threads AS thread
    WHERE thread.user_id = discussion.user_id AND thread.project_id = discussion.project_id
      AND thread.installation_id = discussion.installation_id AND thread.id = discussion.review_thread_id
      AND thread.deleted AND NOT discussion.deleted
    """
  end

  def down do
    execute "DROP TRIGGER chat_catalog_guard_discussion_thread_liveness ON chat_catalog_entries"
    execute "DROP FUNCTION guard_discussion_thread_liveness()"
    execute "DROP TRIGGER review_threads_guard_parent_liveness ON review_threads"
    execute "DROP FUNCTION guard_review_thread_parent_liveness()"
    execute "DROP TRIGGER review_threads_cascade_tombstone ON review_threads"
    execute "DROP FUNCTION tombstone_review_thread_discussions()"
    execute "DROP TRIGGER chat_catalog_cascade_tombstone ON chat_catalog_entries"
    execute "DROP FUNCTION tombstone_chat_review_threads()"
  end
end
