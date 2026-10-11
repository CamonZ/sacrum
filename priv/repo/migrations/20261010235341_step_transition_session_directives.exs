defmodule Sacrum.Repo.Migrations.StepTransitionSessionDirectives do
  @moduledoc """
  Lets a step transition carry the session directive a route decision can:
  `session {mode, step_id?}` for the llm_inference step it leads to. Null
  means a new conversation, as before.
  """

  use Ecto.Migration

  def change do
    alter table(:step_transitions) do
      add :session, :map
    end
  end
end
