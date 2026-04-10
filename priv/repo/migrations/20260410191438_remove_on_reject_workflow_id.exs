defmodule Sacrum.Repo.Migrations.RemoveOnRejectWorkflowId do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      remove :on_reject_workflow_id
    end
  end
end
