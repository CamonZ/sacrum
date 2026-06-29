defmodule Sacrum.Repo.Migrations.RemoveGoogleOauthFromUsers do
  use Ecto.Migration

  def up do
    drop_if_exists index(:users, [:google_sub])

    alter table(:users) do
      remove :google_sub, :text
      remove :avatar_url, :text
    end
  end

  def down do
    alter table(:users) do
      add :google_sub, :text, null: true
      add :avatar_url, :text, null: true
    end

    create unique_index(:users, [:google_sub])
  end
end
