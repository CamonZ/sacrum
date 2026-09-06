defmodule Sacrum.Repo.Migrations.AddKindsAndConsumptionToDaemonCredentials do
  use Ecto.Migration

  def change do
    # Preserve the behavior already applied to the isolated app database.
    # Additional integrity checks belong in the subsequent forward migration.
    alter table(:daemon_credentials) do
      add :credential_kind, :string, null: false, default: "reconnect"
      add :consumed_at, :utc_datetime_usec
    end

    create constraint(:daemon_credentials, :daemon_credentials_credential_kind_check,
             check: "credential_kind IN ('bootstrap', 'reconnect')"
           )

    create index(:daemon_credentials, [:daemon_id, :credential_kind, :status])
  end
end
