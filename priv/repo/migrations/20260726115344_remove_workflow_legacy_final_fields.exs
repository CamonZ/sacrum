defmodule Sacrum.Repo.Migrations.RemoveWorkflowLegacyFinalFields do
  use Ecto.Migration

  def up do
    alter table(:workflows) do
      remove :is_final
    end

    alter table(:workflow_steps) do
      remove :is_final
    end
  end

  def down do
    raise Ecto.MigrationError,
          "cannot restore workflow is_final values after dropping the columns"
  end
end
