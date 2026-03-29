defmodule Sacrum.Repo.Migrations.UpdateDefaultWorkflowUniqueIndex do
  use Ecto.Migration

  def change do
    # Drop the old index that only enforces one default per project
    drop(
      unique_index(:workflows, [:project_id],
        name: :workflows_unique_default_per_project,
        where: "is_default = true"
      )
    )

    # Create new index that enforces one default per (project_id, track) pair
    create(
      unique_index(:workflows, [:project_id, :track],
        name: :workflows_unique_default_per_track,
        where: "is_default = true"
      )
    )
  end
end
