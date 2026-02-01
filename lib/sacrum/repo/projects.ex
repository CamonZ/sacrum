defmodule Sacrum.Repo.Projects do
  @moduledoc """
  CRUD operations for projects.

  ## Error Contract

  - `get/1` returns `{:ok, project}` or `{:error, :not_found}`
  - `get!/1` returns project or raises
  - `get_by/1` returns `{:ok, project}` or `{:error, :not_found}`
  - `all/0` returns `[project]`
  - `insert/2` returns `{:ok, project}` or `{:error, changeset}`
  - `update/2` returns `{:ok, project}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, project}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.User

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Project

  def insert(%User{id: user_id}, attrs), do: insert(user_id, attrs)

  def insert(user_id, attrs) when is_binary(user_id) do
    %Project{user_id: user_id}
    |> Project.create_changeset(attrs)
    |> Repo.insert()
  end

  defoverridable insert: 2

  def update(%Project{} = project, attrs) do
    project
    |> Project.update_changeset(attrs)
    |> Repo.update()
  end
end
