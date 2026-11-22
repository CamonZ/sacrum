defmodule Sacrum.Repo.Migrations.IndexChatCatalogHistory do
  use Ecto.Migration

  # Serves chatCatalogHistory: scoped, live rows ordered by activity with a chat_id tie-breaker.
  def change do
    create index(
             :chat_catalog_entries,
             [:user_id, :project_id, :installation_id, "updated_at DESC", "chat_id DESC"],
             name: :chat_catalog_entries_history_index,
             where: "NOT deleted"
           )
  end
end
