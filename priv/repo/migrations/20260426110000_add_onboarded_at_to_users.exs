defmodule Sacrum.Repo.Migrations.AddOnboardedAtToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :onboarded_at, :utc_datetime_usec, null: true
    end
  end
end
