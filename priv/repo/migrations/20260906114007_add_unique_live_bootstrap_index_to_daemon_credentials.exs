defmodule Sacrum.Repo.Migrations.AddUniqueLiveBootstrapIndexToDaemonCredentials do
  @moduledoc """
  At most one unconsumed active bootstrap may exist per daemon. Revoked and
  consumed bootstraps leave this index, so rotation can re-issue enrollment.
  """

  use Ecto.Migration

  def change do
    create unique_index(:daemon_credentials, [:daemon_id],
             name: :daemon_credentials_one_live_bootstrap_index,
             where: "credential_kind = 'bootstrap' AND status = 'active' AND consumed_at IS NULL"
           )
  end
end
