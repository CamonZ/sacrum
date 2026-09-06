defmodule Sacrum.Repo.Migrations.AddNamesAndEnrollmentToDaemons do
  use Ecto.Migration

  def up do
    alter table(:daemons) do
      add :name, :string
      add :enrolled_at, :utc_datetime_usec
    end

    # Owner-local case-insensitive uniqueness for named daemons. Legacy rows
    # keep NULL names (multiple unnamed rows per owner stay valid) and are
    # never backfilled with fabricated display names or enrollment times.
    create unique_index(:daemons, ["user_id", "lower(name)"],
             name: :daemons_user_id_lower_name_index,
             where: "name IS NOT NULL"
           )
  end

  def down do
    drop unique_index(:daemons, [], name: :daemons_user_id_lower_name_index)

    alter table(:daemons) do
      remove :name
      remove :enrolled_at
    end
  end
end
