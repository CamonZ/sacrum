defmodule Sacrum.Accounts.Projects do
  @moduledoc """
  User-scoped project operations with business logic.

  All operations are scoped to a specific user via `get_by/2` and `list_by/1-2`.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.Projects,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.Projects, as: ProjectsRepo
  alias Sacrum.Repo.Schemas.Project

  @doc """
  Insert a new project for a user.
  """
  @spec insert(String.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, attrs) when is_binary(user_id) do
    %Project{user_id: user_id}
    |> Project.create_changeset(attrs)
    |> ProjectsRepo.insert()
  end

  @doc """
  Update a project.
  """
  @spec update(Project.t(), map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def update(%Project{} = project, attrs) do
    project
    |> Project.update_changeset(attrs)
    |> ProjectsRepo.update()
  end

  @doc """
  Delete a project.
  """
  @spec delete(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Project{} = project) do
    ProjectsRepo.delete(project)
  end
end
