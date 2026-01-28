defmodule Sacrum.Repo.TaskDependencies do
  @moduledoc """
  Functions for managing task dependencies with cycle detection.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskDependency

  def add_dependency(%Task{} = task, %Task{} = depends_on) do
    cond do
      task.project_id != depends_on.project_id ->
        {:error, :different_projects}

      task.id == depends_on.id ->
        {:error, :self_dependency}

      would_create_cycle?(task.id, depends_on.id) ->
        {:error, :circular_dependency}

      true ->
        %TaskDependency{task_id: task.id, depends_on_id: depends_on.id}
        |> TaskDependency.changeset()
        |> Repo.insert()
    end
  end

  def remove_dependency(%Task{} = task, %Task{} = depends_on) do
    case Repo.get_by(TaskDependency, task_id: task.id, depends_on_id: depends_on.id) do
      nil -> {:error, :not_found}
      dep -> Repo.delete(dep)
    end
  end

  def get_direct_blockers(%Task{id: task_id}) do
    from(d in TaskDependency,
      where: d.task_id == ^task_id,
      join: t in Task,
      on: t.id == d.depends_on_id,
      select: t,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  def get_blockers(%Task{} = task) do
    get_blockers_recursive([task.id], MapSet.new(), [])
  end

  defp get_blockers_recursive([], _visited, acc), do: acc

  defp get_blockers_recursive(task_ids, visited, acc) do
    new_ids = Enum.reject(task_ids, &MapSet.member?(visited, &1))

    if new_ids == [] do
      acc
    else
      blockers =
        from(d in TaskDependency,
          where: d.task_id in ^new_ids,
          join: t in Task,
          on: t.id == d.depends_on_id,
          select: t
        )
        |> Repo.all()

      new_visited = Enum.reduce(new_ids, visited, &MapSet.put(&2, &1))
      new_blocker_ids = Enum.map(blockers, & &1.id)
      unique_blockers = Enum.reject(blockers, fn b -> MapSet.member?(visited, b.id) end)

      get_blockers_recursive(new_blocker_ids, new_visited, acc ++ unique_blockers)
    end
  end

  def get_blocking(%Task{id: task_id}) do
    from(d in TaskDependency,
      where: d.depends_on_id == ^task_id,
      join: t in Task,
      on: t.id == d.task_id,
      select: t,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  defp would_create_cycle?(task_id, depends_on_id) do
    # Check if depends_on can reach task_id through existing dependencies
    # (i.e., task_id is already a transitive blocker of depends_on)
    reachable_from?(depends_on_id, task_id, MapSet.new())
  end

  defp reachable_from?(current, target, visited) do
    if current == target do
      true
    else
      if MapSet.member?(visited, current) do
        false
      else
        visited = MapSet.put(visited, current)

        deps =
          from(d in TaskDependency, where: d.task_id == ^current, select: d.depends_on_id)
          |> Repo.all()

        Enum.any?(deps, fn dep_id -> reachable_from?(dep_id, target, visited) end)
      end
    end
  end
end
