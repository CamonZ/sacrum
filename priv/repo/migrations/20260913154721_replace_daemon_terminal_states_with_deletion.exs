defmodule Sacrum.Repo.Migrations.ReplaceDaemonTerminalStatesWithDeletion do
  @moduledoc """
  Replaces daemon terminal rows with hard deletion.

  Existing `revoked` and `removed` daemon identities are intentionally
  deleted during this forward migration. Their daemon credentials disappear
  through the existing `daemon_credentials.daemon_id ON DELETE CASCADE`
  foreign key. This is a destructive, non-reversible data policy: a rollback
  restores the columns and constraint but cannot restore those identities or
  their credential audit rows.
  """

  use Ecto.Migration

  def up do
    execute("DELETE FROM daemons WHERE status IN ('revoked', 'removed')")

    drop constraint(:daemons, :daemons_status_check)

    alter table(:daemons) do
      remove :removed_at
    end

    create constraint(:daemons, :daemons_status_check, check: "status IN ('pending', 'active')")
  end

  def down do
    drop constraint(:daemons, :daemons_status_check)

    alter table(:daemons) do
      add :removed_at, :utc_datetime_usec
    end

    create constraint(:daemons, :daemons_status_check,
             check: "status IN ('pending', 'active', 'revoked', 'removed')"
           )
  end
end
