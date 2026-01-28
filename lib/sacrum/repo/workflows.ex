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
  end

  def update(%Workflow{} = workflow, attrs) do
    workflow
    |> Workflow.update_changeset(attrs)
    |> Repo.update()
  end

  def delete(%Workflow{} = workflow), do: Repo.delete(workflow)
end
