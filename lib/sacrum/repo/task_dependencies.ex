defmodule Sacrum.Repo.TaskDependencies do
  @moduledoc """
  Functions for managing task dependencies with cycle detection.

  ## Error Contract

  - `add_dependency/2` returns `{:ok, dependency}` or `{:error, atom}`
  - `remove_dependency/2` returns `{:ok, dependency}` or `{:error, :not_found}`
  - `find_path/2` returns `{:ok, [task_ids]}` (empty list if no path exists)

  ## Domain-Specific Errors

  `add_dependency/2` may return `{:error, atom}` for:
  - `:different_projects` - when tasks belong to different projects
  - `:self_dependency` - when task depends on itself
  - `:circular_dependency` - when adding the dependency would create a cycle

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
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
        %TaskDependency{task_id: task.id, depends_on_id: depends_on.id, user_id: task.user_id}
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
    # Build the recursive CTE query for transitive blockers
    base_query =
      from(d in TaskDependency,
        where: d.task_id == ^task.id,
        select: %{id: d.depends_on_id}
      )

    recursive_query =
      from(d in TaskDependency,
        join: b in fragment("blockers"),
        on: d.task_id == b.id,
        select: %{id: d.depends_on_id}
      )

    blocker_cte = union_all(base_query, ^recursive_query)

    # Main query using the CTE
    from(t in Task)
    |> with_cte("blockers", as: ^blocker_cte)
    |> recursive_ctes(true)
    |> join(:inner, [t], b in fragment("blockers"), on: t.id == b.id)
    |> select([t], t)
    |> order_by([t], asc: t.inserted_at)
    |> distinct(true)
    |> Repo.all()
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
