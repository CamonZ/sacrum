defmodule Sacrum.Repo.Migrations.AddUniqueDefaultWorkflowPerProject do
  use Ecto.Migration

  def change do
    create unique_index(:workflows, [:project_id],
             name: :workflows_unique_default_per_project,
             where: "is_default = true"
           )
  end
end
