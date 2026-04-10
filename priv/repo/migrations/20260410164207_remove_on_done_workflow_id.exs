defmodule Sacrum.Repo.Migrations.RemoveOnDoneWorkflowId do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      remove :on_done_workflow_id
    end
  end
end
