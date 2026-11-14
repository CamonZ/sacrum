defmodule Sacrum.Repo.Migrations.DaemonAccessAndRefreshCredentials do
  @moduledoc """
  Replaces Argon2-hashed reconnect credentials with SHA-256-hashed access and
  refresh credentials.

  Existing `reconnect` rows and unconsumed Argon2 `bootstrap` rows cannot be
  verified by a hash lookup, so they are removed/revoked. Affected daemons keep
  their identity; owners issue a new registration token with
  `rotateDaemonCredentials`.

  This is a hard cutover: old and new app versions must not run side by side.

  Rollback is lossy: it deletes access/refresh rows and revokes unconsumed
  registration tokens (SHA-256 hashes the old Argon2 code cannot verify). Use a
  forward migration instead.
  """

  use Ecto.Migration

  def up do
    execute "DELETE FROM daemon_credentials WHERE credential_kind = 'reconnect'"

    execute """
    UPDATE daemon_credentials
    SET status = 'revoked', revoked_at = now(), updated_at = now()
    WHERE credential_kind = 'bootstrap' AND status = 'active' AND consumed_at IS NULL
    """

    drop constraint(:daemon_credentials, :daemon_credentials_credential_kind_check)

    create constraint(:daemon_credentials, :daemon_credentials_credential_kind_check,
             check: "credential_kind IN ('bootstrap', 'access', 'refresh')"
           )

    execute "ALTER TABLE daemon_credentials ALTER COLUMN credential_kind DROP DEFAULT"
  end

  def down do
    execute """
    UPDATE daemon_credentials
    SET status = 'revoked', revoked_at = now(), updated_at = now()
    WHERE credential_kind = 'bootstrap' AND status = 'active' AND consumed_at IS NULL
    """

    execute "DELETE FROM daemon_credentials WHERE credential_kind IN ('access', 'refresh')"

    drop constraint(:daemon_credentials, :daemon_credentials_credential_kind_check)

    create constraint(:daemon_credentials, :daemon_credentials_credential_kind_check,
             check: "credential_kind IN ('bootstrap', 'reconnect')"
           )

    execute "ALTER TABLE daemon_credentials ALTER COLUMN credential_kind SET DEFAULT 'reconnect'"
  end
end
