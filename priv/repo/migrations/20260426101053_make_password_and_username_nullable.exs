defmodule Sacrum.Repo.Migrations.MakePasswordAndUsernameNullable do
  use Ecto.Migration

  def change do
    alter table(:users) do
      modify :password_hash, :string, null: true
      modify :username, :string, null: true
    end
  end
end
