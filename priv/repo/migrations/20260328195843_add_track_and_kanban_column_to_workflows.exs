defmodule Sacrum.Repo.Migrations.AddTrackAndKanbanColumnToWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :track, :string
      add :kanban_column, :string
    end
  end
end
