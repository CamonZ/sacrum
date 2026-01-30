defmodule Sacrum.Repo.TaskHierarchy do
  @moduledoc """
  Functions for managing task parent-child hierarchy.

  ## Error Contract

  - `set_parent/2` returns `{:ok, hierarchy}` or `{:error, changeset}`
  - `remove_parent/1` returns `{:ok, hierarchy}` or `{:error, :not_found}`
  - `get_parent/1` returns `{:ok, parent_task}` or `{:error, :not_found}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  Functions like `get_children/1`, `get_ancestors/1`, and `get_descendants/1` return
  task structs but do not automatically preload associations.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskHierarchy

  def set_parent(%Task{} = child, %Task{} = parent) do
    %TaskHierarchy{parent_id: parent.id, child_id: child.id}
    |> TaskHierarchy.changeset()
    |> Repo.insert()
  end

  def remove_parent(%Task{id: child_id}) do
    case Repo.get_by(TaskHierarchy, child_id: child_id) do
      nil -> {:error, :not_found}
      hierarchy -> Repo.delete(hierarchy)
    end
  end

  def get_parent(%Task{id: child_id}) do
    case Repo.get_by(TaskHierarchy, child_id: child_id) do
      nil ->
        {:error, :not_found}

      hierarchy ->
        {:ok, Repo.get!(Task, hierarchy.parent_id)}
    end
  end

  def get_children(%Task{id: parent_id}) do
    from(h in TaskHierarchy,
      where: h.parent_id == ^parent_id,
      join: t in Task,
      on: t.id == h.child_id,
      select: t,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  def get_ancestors(%Task{} = task) do
    get_ancestors_recursive(task.id, [])
  end

  defp get_ancestors_recursive(task_id, acc) do
    case Repo.get_by(TaskHierarchy, child_id: task_id) do
      nil ->
        Enum.reverse(acc)

      hierarchy ->
        parent = Repo.get!(Task, hierarchy.parent_id)
        get_ancestors_recursive(parent.id, [parent | acc])
    end
  end

  def get_descendants(%Task{} = task) do
    get_descendants_recursive([task.id], [])
  end

  defp get_descendants_recursive([], acc), do: acc

  defp get_descendants_recursive(parent_ids, acc) do
    children =
      from(h in TaskHierarchy,
        where: h.parent_id in ^parent_ids,
        join: t in Task,
        on: t.id == h.child_id,
        select: t
      )
      |> Repo.all()

    child_ids = Enum.map(children, & &1.id)
    get_descendants_recursive(child_ids, acc ++ children)
  end

  @doc """
  Builds a recursive tree structure from a root task.
  Returns a map with the task data and a :children list.
  """
  def build_tree(%Task{} = task) do
    children = get_children(task)

    %{
      task: task,
      children: Enum.map(children, &build_tree/1)
    }
  end
end
