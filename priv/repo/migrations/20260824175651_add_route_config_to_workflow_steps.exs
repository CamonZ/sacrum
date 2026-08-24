defmodule Sacrum.Repo.Migrations.AddRouteConfigToWorkflowSteps do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      add :route_config, :map, null: true
    end
  end
end
