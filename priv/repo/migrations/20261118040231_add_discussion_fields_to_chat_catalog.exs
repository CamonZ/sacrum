defmodule Sacrum.Repo.Migrations.AddDiscussionFieldsToChatCatalog do
  use Ecto.Migration

  def change do
    alter table(:chat_catalog_entries) do
      add :review_thread_id, :uuid
    end

    create unique_index(
             :review_threads,
             [:id, :parent_chat_id, :project_id, :installation_id, :user_id],
             name: :review_threads_discussion_scope_index
           )

    execute(
      """
      ALTER TABLE chat_catalog_entries
        ADD CONSTRAINT chat_catalog_review_thread_scope_fkey
        FOREIGN KEY (review_thread_id, parent_chat_id, project_id, installation_id, user_id)
        REFERENCES review_threads (id, parent_chat_id, project_id, installation_id, user_id)
      """,
      "ALTER TABLE chat_catalog_entries DROP CONSTRAINT chat_catalog_review_thread_scope_fkey"
    )

    create constraint(:chat_catalog_entries, :chat_catalog_discussion_links_valid,
             check: """
             CASE COALESCE(metadata -> 'kind', '"chat"'::jsonb)
               WHEN '"chat"'::jsonb THEN review_thread_id IS NULL
               WHEN '"discussion"'::jsonb THEN review_thread_id IS NOT NULL AND parent_chat_id IS NOT NULL
               ELSE FALSE
             END
             """
           )
  end
end
