defmodule Sacrum.Accounts.Projects do
  @moduledoc """
  User-scoped project operations with business logic.

  All operations are scoped to a specific user via `get_by/2` and `list_by/1-2`.
  """

  use Sacrum.GenericResource,
    schema: Sacrum.Repo.Schemas.Project,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo
  alias Sacrum.Repo.Projects, as: ProjectsRepo
  alias Sacrum.Repo.Schemas.Project

  @doc """
  Insert a new project for a user.
  """
  def insert(user_id, attrs) when is_binary(user_id) do
    %Project{user_id: user_id}
    |> Project.create_changeset(attrs)
    |> ProjectsRepo.insert()
  end

  @doc """
  Update a project.
  """
  def update(%Project{} = project, attrs) do
    project
    |> Project.update_changeset(attrs)
    |> ProjectsRepo.update()
  end

  @doc """
  Delete a project.
  """
  def delete(%Project{} = project) do
    ProjectsRepo.delete(project)
  end
end
