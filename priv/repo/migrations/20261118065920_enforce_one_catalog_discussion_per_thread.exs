defmodule Sacrum.Repo.Migrations.EnforceOneCatalogDiscussionPerThread do
  use Ecto.Migration

  def change do
    create unique_index(:chat_catalog_entries, [:user_id, :installation_id, :review_thread_id],
             name: :chat_catalog_one_discussion_per_thread,
             where: "review_thread_id IS NOT NULL"
           )
  end
end
