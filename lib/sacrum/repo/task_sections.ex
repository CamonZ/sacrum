defmodule Sacrum.Repo.TaskSections do
  @moduledoc """
  CRUD operations for task sections, scoped to a task.

  ## Error Contract

  - `get/1` returns `{:ok, section}` or `{:error, :not_found}`
  - `insert/2` returns `{:ok, section}` or `{:error, changeset}`
  - `update/2` returns `{:ok, section}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, section}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection

  def get(id) do
    case Repo.get(TaskSection, id) do
      nil -> {:error, :not_found}
      section -> {:ok, section}
    end
  end

  def list_for_task(%Task{id: task_id}), do: list_for_task(task_id)

  def list_for_task(task_id) when is_binary(task_id) do
    from(s in TaskSection,
      where: s.task_id == ^task_id,
      order_by: [asc: s.section_order, asc: s.inserted_at]
    )
    |> Repo.all()
  end

  def insert(%Task{id: task_id}, attrs), do: insert(task_id, attrs)

  def insert(task_id, attrs) when is_binary(task_id) do
    %TaskSection{task_id: task_id}
    |> TaskSection.changeset(attrs)
    |> Repo.insert()
  end

  def update(%TaskSection{} = section, attrs) do
    section
    |> TaskSection.changeset(attrs)
    |> Repo.update()
  end

  def delete(%TaskSection{} = section), do: Repo.delete(section)
end
