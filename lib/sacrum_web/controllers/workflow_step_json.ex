defmodule SacrumWeb.WorkflowStepJSON do
  alias Sacrum.Repo.Schemas.WorkflowStep

  def index(%{steps: steps}) do
    %{data: for(step <- steps, do: data(step))}
  end

  def show(%{step: step}) do
    %{data: data(step)}
  end

  defp data(%WorkflowStep{} = step) do
    %{
      id: step.id,
      name: step.name,
      goal: step.goal,
      agents: step.agents,
      skills: step.skills,
      agent_config: step.agent_config,
      is_final: step.is_final,
      step_order: step.step_order,
      workflow_id: step.workflow_id,
      inserted_at: step.inserted_at,
      updated_at: step.updated_at
    }
  end
end
