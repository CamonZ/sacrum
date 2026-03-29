defmodule Sacrum.Repo.Migrations.RemoveTrackFromWorkflowsAndTasks do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      remove :track
    end

    alter table(:tasks) do
      remove :track
    end
  end
end
