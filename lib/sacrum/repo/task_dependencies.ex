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

  @doc """
  Finds the shortest dependency path between two tasks using BFS.
  Returns {:ok, [task_ids]} or {:ok, []} if no path exists.
  """
  def find_path(%Task{id: from_id}, %Task{id: to_id}) do
    bfs_path(from_id, to_id)
  end

  defp bfs_path(from_id, to_id) do
    queue = :queue.in({from_id, [from_id]}, :queue.new())
    visited = MapSet.new([from_id])
    do_bfs(queue, visited, to_id)
  end

  defp do_bfs(queue, visited, target) do
    case :queue.out(queue) do
      {:empty, _} ->
        {:ok, []}

      {{:value, {current, path}}, rest_queue} ->
        if current == target do
          {:ok, path}
        else
          neighbor_ids =
            from(d in TaskDependency, where: d.task_id == ^current, select: d.depends_on_id)
            |> Repo.all()

          {new_queue, new_visited} =
            Enum.reduce(neighbor_ids, {rest_queue, visited}, fn nid, {q, v} ->
              if MapSet.member?(v, nid) do
                {q, v}
              else
                {:queue.in({nid, path ++ [nid]}, q), MapSet.put(v, nid)}
              end
            end)

          do_bfs(new_queue, new_visited, target)
        end
    end
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
