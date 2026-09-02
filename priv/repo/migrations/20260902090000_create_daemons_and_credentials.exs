defmodule Sacrum.Repo.Migrations.CreateDaemonsAndCredentials do
  use Ecto.Migration

  def change do
    create table(:daemons, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:daemons, [:user_id])
    create unique_index(:daemons, [:id])

    create table(:daemon_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :daemon_id, references(:daemons, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:daemon_credentials, [:daemon_id])
    create unique_index(:daemon_credentials, [:token_hash])
  end
end
