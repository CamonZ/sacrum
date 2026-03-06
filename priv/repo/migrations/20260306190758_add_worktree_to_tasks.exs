defmodule Sacrum.Repo.Migrations.AddWorktreeToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :worktree, :string
    end
  end
end
