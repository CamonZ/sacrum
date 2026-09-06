defmodule Sacrum.Repo.Migrations.AddDaemonsStatusCheck do
  @moduledoc """
  Constrains daemon lifecycle status to the documented finite set, including
  the `removed` tombstone added by the prior migration.
  """

  use Ecto.Migration

  def up do
    create constraint(:daemons, :daemons_status_check,
             check: "status IN ('pending', 'active', 'revoked', 'removed')"
           )
  end

  def down do
    drop constraint(:daemons, :daemons_status_check)
  end
end
