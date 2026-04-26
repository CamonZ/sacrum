defmodule Sacrum.Repo.Migrations.AddGoogleOauthToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :google_sub, :text, null: true
      add :avatar_url, :text, null: true
    end

    create unique_index(:users, [:google_sub])
  end
end
