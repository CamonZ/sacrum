defmodule Sacrum.Repo.Migrations.AddTrackToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :track, :string
    end
  end
end
