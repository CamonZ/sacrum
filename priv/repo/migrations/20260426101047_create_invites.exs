defmodule Sacrum.Repo.Migrations.CreateInvites do
  use Ecto.Migration

  def change do
    create table(:invites, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :citext, null: false
      add :invited_by_id, references(:users, on_delete: :restrict, type: :binary_id)
      add :accepted_at, :utc_datetime_usec, null: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:invites, [:email])
    create index(:invites, [:invited_by_id])
  end
end
