defmodule Sacrum.Repo.Migrations.AddRemovalTombstoneToDaemons do
  use Ecto.Migration

  def up do
    # Terminal soft-removal marker. Unregister keeps the row (identity
    # references, credential audit and execution history are preserved) and
    # sets status 'removed' plus this timestamp; no rows are deleted.
    alter table(:daemons) do
      add :removed_at, :utc_datetime_usec
    end
  end

  def down do
    alter table(:daemons) do
      remove :removed_at
    end
  end
end
