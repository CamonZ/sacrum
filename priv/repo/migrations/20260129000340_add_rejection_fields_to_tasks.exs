defmodule Sacrum.Repo.Migrations.AddRejectionFieldsToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :rejection_reason, :text
      add :revision_feedback, :text
    end
  end
end
