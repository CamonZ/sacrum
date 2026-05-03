defmodule Sacrum.Repo.Migrations.AddIsFinalToWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :is_final, :boolean, default: false, null: false
    end

    execute(
      """
      UPDATE workflows w
      SET is_final = NOT EXISTS (
        SELECT 1 FROM workflow_transitions wt
        WHERE wt.from_workflow_id = w.id
      )
      """,
      ""
    )
  end
end
