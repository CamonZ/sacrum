defmodule SacrumWeb.WorkflowStepJSON do
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.StepTransition

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
      transitions: transitions(step),
      inserted_at: step.inserted_at,
      updated_at: step.updated_at
    }
  end

  defp transitions(%WorkflowStep{transitions: transitions}) when is_list(transitions) do
    Enum.map(transitions, &transition_data/1)
  end

  defp transitions(_), do: nil

  defp transition_data(%StepTransition{} = t) do
    %{
      id: t.id,
      to_step_id: t.to_step_id,
      label: t.label
    }
  end
end
