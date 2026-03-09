defmodule Sacrum.Repo.Migrations.AddPromptAndEvalPromptToWorkflowSteps do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      add :prompt, :text
      add :eval_prompt, :text
    end
  end
end
