defmodule Sacrum.Repo.TaskHierarchy do
  @moduledoc """
  Functions for managing task parent-child hierarchy.

  This module retains the read helpers used by orchestration and routing. Task
  writes go through `Sacrum.Accounts.Tasks.update/2` so the task changeset and
  database constraints enforce parent scope consistently.

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  Functions like `get_children/1` and `get_descendants/1` return
  task structs but do not automatically preload associations.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task

  @spec get_parent(Task.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def get_parent(%Task{parent_id: nil}), do: {:error, :not_found}

  def get_parent(%Task{parent_id: parent_id}) do
    case Repo.get(Task, parent_id) do
      nil -> {:error, :not_found}
      parent -> {:ok, parent}
    end
  end

  @spec get_children(Task.t()) :: [Task.t()]
  def get_children(%Task{id: parent_id}) do
    Repo.all(
      from(t in Task,
        where: t.parent_id == ^parent_id,
        order_by: [asc: t.inserted_at]
      )
    )
  end

  @spec get_descendants(Task.t()) :: [Task.t()]
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
end
