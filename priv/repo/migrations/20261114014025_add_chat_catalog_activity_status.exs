defmodule Sacrum.Repo.Migrations.AddChatCatalogActivityStatus do
  use Ecto.Migration

  def change do
    alter table(:chat_catalog_entries) do
      add :status, :string, null: false, default: "idle"
    end

    create constraint(:chat_catalog_entries, :chat_catalog_status_valid,
             check: "status IN ('idle', 'working')"
           )
  end
end
