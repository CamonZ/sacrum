defmodule Sacrum.Repo.Workflows do
  @moduledoc """
  CRUD operations for workflows, scoped to a project.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Workflow

  def get(id) do
    case Repo.get(Workflow, id) do
      nil -> {:error, :not_found}
      workflow -> {:ok, workflow}
    end
  end

  def get!(id), do: Repo.get!(Workflow, id)

  def list(%Project{id: project_id}), do: list(project_id)

  def list(project_id) when is_binary(project_id) do
    from(w in Workflow,
      where: w.project_id == ^project_id,
      order_by: [asc: w.display_order, asc: w.inserted_at]
    )
    |> Repo.all()
  end

  def insert(%Project{id: project_id}, attrs), do: insert(project_id, attrs)

  def insert(project_id, attrs) when is_binary(project_id) do
    %Workflow{project_id: project_id}
    |> Workflow.create_changeset(attrs)
    |> Repo.insert()
    |> broadcast(:workflow_created)
  end

  def update(%Workflow{} = workflow, attrs) do
    workflow
    |> Workflow.update_changeset(attrs)
    |> Repo.update()
    |> broadcast(:workflow_updated)
  end

  def delete(%Workflow{} = workflow) do
    case Repo.delete(workflow) do
      {:ok, deleted} ->
        broadcast_event(deleted, :workflow_deleted)
        {:ok, deleted}

      error ->
        error
    end
  end

  defp broadcast({:ok, workflow}, event) do
    broadcast_event(workflow, event)
    {:ok, workflow}
  end

  defp broadcast({:error, _} = error, _event), do: error

  defp broadcast_event(workflow, event) do
    workflow = Repo.preload(workflow, :project)

    case workflow.project do
      %Project{slug: slug} ->
        apply(SacrumWeb.ProjectChannel, :"broadcast_#{event}", [slug, workflow])

      _ ->
        :ok
    end
  end
end
