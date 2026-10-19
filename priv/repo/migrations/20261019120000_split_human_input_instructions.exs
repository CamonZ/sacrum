defmodule Sacrum.Repo.Migrations.SplitHumanInputInstructions do
  @moduledoc """
  Moves `human_input` configs to version 2: `instructions` becomes `question`
  and `role` starts null. There is no compatibility path: rolling back leaves
  the stored configs at version 2.
  """

  use Ecto.Migration

  def up do
    for table <- ["workflow_steps", "step_executions"] do
      execute """
      UPDATE #{table}
      SET config = (config - 'instructions')
        || jsonb_build_object(
          'version', 2,
          'role', NULL,
          'question', config -> 'instructions'
        )
      WHERE step_type = 'human_input' AND config IS NOT NULL
      """
    end
  end

  def down, do: :ok
end
