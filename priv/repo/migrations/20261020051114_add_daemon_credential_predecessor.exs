defmodule Sacrum.Repo.Migrations.AddDaemonCredentialPredecessor do
  use Ecto.Migration

  def change do
    alter table(:daemon_credentials) do
      add :predecessor_id,
          references(:daemon_credentials, type: :binary_id, on_delete: :nilify_all)
    end

    create unique_index(:daemon_credentials, [:predecessor_id],
             where: "status = 'active' AND predecessor_id IS NOT NULL",
             name: :daemon_credentials_one_active_successor_index
           )
  end
end
