defmodule Sacrum.Repo.Migrations.AddDraftToStepExecutions do
  use Ecto.Migration

  def change do
    alter table(:step_executions) do
      add :draft, :map, null: false, default: %{}
      add :draft_updated_at, :utc_datetime_usec
    end
  end
end
