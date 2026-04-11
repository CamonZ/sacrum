defmodule Sacrum.Repo.Migrations.DropEvalPromptColumn do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      remove :eval_prompt
    end
  end
end
