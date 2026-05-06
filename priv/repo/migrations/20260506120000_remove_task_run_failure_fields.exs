defmodule Sacrum.Repo.Migrations.RemoveTaskRunFailureFields do
  use Ecto.Migration

  def up do
    alter table(:task_runs) do
      remove :failure_kind
      remove :failure_reason
      remove :failure_context
    end
  end

  def down do
    alter table(:task_runs) do
      add :failure_kind, :string
      add :failure_reason, :text
      add :failure_context, :map, default: %{}
    end
  end
end
