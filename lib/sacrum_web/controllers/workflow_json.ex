defmodule SacrumWeb.WorkflowJSON do
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowTransition

  def index(%{workflows: workflows}) do
    %{data: for(workflow <- workflows, do: data(workflow))}
  end

  def show(%{workflow: workflow}) do
    %{data: data(workflow)}
  end

  defp data(%Workflow{} = workflow) do
    base = %{
      id: workflow.id,
      name: workflow.name,
      description: workflow.description,
      auto_advance: workflow.auto_advance,
      is_default: workflow.is_default,
      display_order: workflow.display_order,
      metadata: workflow.metadata,
      initial_step_id: workflow.initial_step_id,
      project_id: workflow.project_id,
      inserted_at: workflow.inserted_at,
      updated_at: workflow.updated_at
    }

    maybe_add_transitions(base, workflow)
  end

  defp maybe_add_transitions(base, %Workflow{transitions: transitions})
       when is_list(transitions) do
    Map.put(base, :transitions, Enum.map(transitions, &transition_data/1))
  end

  defp maybe_add_transitions(base, _workflow), do: base

  defp transition_data(%WorkflowTransition{} = t) do
    %{
      id: t.id,
      to_workflow_id: t.to_workflow_id,
      target_step_id: t.target_step_id,
      label: t.label
    }
  end
end
