defmodule SacrumWeb.WorkflowJSON do
  alias Sacrum.Repo.Schemas.Workflow

  def index(%{workflows: workflows}) do
    %{data: for(workflow <- workflows, do: data(workflow))}
  end

  def show(%{workflow: workflow}) do
    %{data: data(workflow)}
  end

  defp data(%Workflow{} = workflow) do
    %{
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
  end
end
