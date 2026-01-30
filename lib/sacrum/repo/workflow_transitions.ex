defmodule Sacrum.Repo.WorkflowTransitions do
  @moduledoc """
  CRUD operations for workflow-to-workflow transitions.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowTransition

  def get(id) do
    case Repo.get(WorkflowTransition, id) do
      nil -> {:error, :not_found}
      transition -> {:ok, transition}
    end
  end

  def list_for_workflow(%Workflow{id: workflow_id}), do: list_for_workflow(workflow_id)

  def list_for_workflow(from_workflow_id) when is_binary(from_workflow_id) do
    from(t in WorkflowTransition,
      where: t.from_workflow_id == ^from_workflow_id,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  def list_for_project(project_id) when is_binary(project_id) do
    from(t in WorkflowTransition,
      join: w in Workflow,
      on: w.id == t.from_workflow_id,
      where: w.project_id == ^project_id,
      preload: [:from_workflow, :to_workflow],
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  def insert(attrs) do
    %WorkflowTransition{}
    |> WorkflowTransition.create_changeset(attrs)
    |> Repo.insert()
  end

  def delete(%WorkflowTransition{} = transition) do
    Repo.delete(transition)
  end
end
