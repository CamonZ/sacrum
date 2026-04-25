defmodule Sacrum.Repo.Migrations.CreateWaitlistEntries do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext"

    create table(:waitlist_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:waitlist_entries, [:email])
  end
end
