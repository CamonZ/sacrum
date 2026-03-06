defmodule Sacrum.Repo.TaskHierarchy do
  @moduledoc """
  Functions for managing task parent-child hierarchy.

  ## Error Contract

  - `set_parent/2` returns `{:ok, task}` or `{:error, changeset}`
  - `remove_parent/1` returns `{:ok, task}` or `{:error, :not_found}`
  - `get_parent/1` returns `{:ok, parent_task}` or `{:error, :not_found}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  Functions like `get_children/1`, `get_ancestors/1`, and `get_descendants/1` return
  task structs but do not automatically preload associations.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task

  def set_parent(%Task{} = child, %Task{} = parent) do
    child
    |> Ecto.Changeset.change(parent_id: parent.id)
    |> Repo.update()
  end

  def remove_parent(%Task{parent_id: nil}), do: {:error, :not_found}

  def remove_parent(%Task{} = task) do
    task
    |> Ecto.Changeset.change(parent_id: nil)
    |> Repo.update()
  end

  def get_parent(%Task{parent_id: nil}), do: {:error, :not_found}

  def get_parent(%Task{parent_id: parent_id}) do
    case Repo.get(Task, parent_id) do
      nil -> {:error, :not_found}
      parent -> {:ok, parent}
    end
  end

  def get_children(%Task{id: parent_id}) do
    Repo.all(
      from(t in Task,
        where: t.parent_id == ^parent_id,
        order_by: [asc: t.inserted_at]
      )
    )
  end

  def get_ancestors(%Task{parent_id: nil}), do: []

  def get_ancestors(%Task{} = task) do
    ancestor_cte =
      Task
      |> where([t], t.id == ^task.parent_id)
      |> select([t], %{id: t.id, parent_id: t.parent_id, depth: fragment("1")})
      |> union_all(
        ^from(t in Task,
          join: a in fragment("ancestors"),
          on: t.id == a.parent_id,
          select: %{id: t.id, parent_id: t.parent_id, depth: fragment("? + 1", a.depth)}
        )
      )

    Task
    |> with_cte("ancestors", as: ^ancestor_cte)
    |> recursive_ctes(true)
    |> join(:inner, [t], a in fragment("ancestors"), on: t.id == a.id)
    |> order_by([t, a], asc: a.depth)
    |> select([t], t)
    |> Repo.all()
  end

  def get_descendants(%Task{} = task) do
    descendant_cte =
      Task
      |> where([t], t.parent_id == ^task.id)
      |> select([t], %{id: t.id})
      |> union_all(
        ^from(t in Task,
          join: d in fragment("descendants"),
          on: t.parent_id == d.id,
          select: %{id: t.id}
        )
      )

    Task
    |> with_cte("descendants", as: ^descendant_cte)
    |> recursive_ctes(true)
    |> join(:inner, [t], d in fragment("descendants"), on: t.id == d.id)
    |> select([t], t)
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
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
