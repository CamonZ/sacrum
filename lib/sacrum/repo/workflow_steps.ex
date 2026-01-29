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
    |> broadcast(:step_created)
  end

  def update(%WorkflowStep{} = step, attrs) do
    step
    |> WorkflowStep.update_changeset(attrs)
    |> Repo.update()
    |> broadcast(:step_updated)
  end

  def delete(%WorkflowStep{} = step) do
    case Repo.delete(step) do
      {:ok, deleted} ->
        broadcast_event(deleted, :step_deleted)
        {:ok, deleted}

      error ->
        error
    end
  end

  defp broadcast({:ok, step}, event) do
    broadcast_event(step, event)
    {:ok, step}
  end

  defp broadcast({:error, _} = error, _event), do: error

  defp broadcast_event(step, event) do
    step = Repo.preload(step, workflow: :project)

    case step do
      %{workflow: %{project: %{slug: slug}}} ->
        apply(SacrumWeb.ProjectChannel, :"broadcast_#{event}", [slug, step])

      _ ->
        :ok
    end
  end
end
