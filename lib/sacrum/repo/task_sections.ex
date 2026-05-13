defmodule Sacrum.Repo.TaskSections do
  @moduledoc """
  CRUD operations for task sections.

  ## Error Contract

  - `get/1` returns `{:ok, section}` or `{:error, :not_found}`
  - `get!/1` returns section or raises
  - `get_by/1` returns `{:ok, section}` or `{:error, :not_found}`
  - `all/0` returns `[section]`
  - `insert/1` returns `{:ok, section}` or `{:error, changeset}`
  - `update/1` returns `{:ok, section}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, section}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.TaskSection

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection

  @spec insert(Task.t(), map()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Task{id: task_id, project_id: project_id, user_id: user_id}, attrs) do
    %TaskSection{task_id: task_id, project_id: project_id, user_id: user_id}
    |> TaskSection.changeset(attrs)
    |> Repo.insert()
  end

  @spec update(TaskSection.t(), map()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def update(%TaskSection{} = section, attrs) do
    section
    |> TaskSection.changeset(attrs)
    |> Repo.update()
  end

  @spec delete(TaskSection.t()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def delete(%TaskSection{} = section) do
    Repo.delete(section)
  end
end
