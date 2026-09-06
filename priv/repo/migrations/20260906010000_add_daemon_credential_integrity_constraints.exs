defmodule Sacrum.Repo.Migrations.AddDaemonCredentialIntegrityConstraints do
  @moduledoc """
  Adds the integrity constraints omitted by the initial credential-kind
  migration. This forward correction is safe for the supported legacy policy:
  existing rows are reconnect credentials and valid active/revoked states.
  """

  use Ecto.Migration

  def up do
    create constraint(:daemon_credentials, :daemon_credentials_status_check,
             check: "status IN ('active', 'revoked')"
           )

    create constraint(:daemon_credentials, :daemon_credentials_revoked_at_check,
             check: "revoked_at IS NULL OR status = 'revoked'"
           )

    create constraint(:daemon_credentials, :daemon_credentials_consumed_at_check,
             check: "consumed_at IS NULL OR credential_kind = 'bootstrap'"
           )
  end

  def down do
    drop constraint(:daemon_credentials, :daemon_credentials_consumed_at_check)
    drop constraint(:daemon_credentials, :daemon_credentials_revoked_at_check)
    drop constraint(:daemon_credentials, :daemon_credentials_status_check)
  end
end
