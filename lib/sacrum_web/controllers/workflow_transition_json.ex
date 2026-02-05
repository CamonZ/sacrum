defmodule SacrumWeb.WorkflowTransitionJSON do
  alias Sacrum.Repo.Schemas.WorkflowTransition

  def show(%{transition: transition}) do
    %{data: data(transition)}
  end

  defp data(%WorkflowTransition{} = transition) do
    %{
      id: transition.id,
      from_workflow_id: transition.from_workflow_id,
      to_workflow_id: transition.to_workflow_id,
      target_step_id: transition.target_step_id,
      label: transition.label,
      inserted_at: transition.inserted_at,
      updated_at: transition.updated_at
    }
  end
end
