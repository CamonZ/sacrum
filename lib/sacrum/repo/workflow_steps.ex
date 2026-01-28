defmodule Sacrum.Repo.WorkflowSteps do
  @moduledoc """
  CRUD operations for workflow steps, scoped to a workflow.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowStep

  def get(id) do
    case Repo.get(WorkflowStep, id) do
      nil -> {:error, :not_found}
      step -> {:ok, step}
    end
  end

  def get!(id), do: Repo.get!(WorkflowStep, id)

  def list(%Workflow{id: workflow_id}), do: list(workflow_id)

  def list(workflow_id) when is_binary(workflow_id) do
    from(s in WorkflowStep,
      where: s.workflow_id == ^workflow_id,
      order_by: [asc: s.step_order, asc: s.inserted_at]
    )
    |> Repo.all()
  end

  def insert(%Workflow{id: workflow_id}, attrs), do: insert(workflow_id, attrs)

  def insert(workflow_id, attrs) when is_binary(workflow_id) do
    %WorkflowStep{workflow_id: workflow_id}
    |> WorkflowStep.create_changeset(attrs)
    |> Repo.insert()
  end

  def update(%WorkflowStep{} = step, attrs) do
    step
    |> WorkflowStep.update_changeset(attrs)
    |> Repo.update()
  end

  def delete(%WorkflowStep{} = step), do: Repo.delete(step)
end
