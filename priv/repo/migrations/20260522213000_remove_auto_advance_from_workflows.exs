defmodule Sacrum.Repo.Migrations.RemoveAutoAdvanceFromWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      remove :auto_advance, :boolean, default: false
    end
  end
end
