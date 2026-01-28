defmodule Sacrum.Repo.Tasks do
  @moduledoc """
  CRUD operations for tasks, scoped to a project.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.TaskDependency

  def get(id) do
    case Repo.get(Task, id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  def get!(id), do: Repo.get!(Task, id)

  def get_by_short_id(short_id) do
    case Repo.get_by(Task, short_id: short_id) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  def list(%Project{id: project_id}), do: list(project_id)

  def list(project_id) when is_binary(project_id) do
    from(t in Task, where: t.project_id == ^project_id, order_by: [asc: t.inserted_at])
    |> Repo.all()
  end

  @doc """
  Lists tasks with optional filters.

  Options:
    - `:project_id` - filter by project
    - `:level` - filter by task level
    - `:parent_id` - filter by parent task (via hierarchy)
    - `:blocked` - when false, exclude tasks with incomplete dependencies
    - `:search` - text search on title/description
  """
  def list_tasks(opts \\ []) do
    Task
    |> apply_filter(:project_id, opts[:project_id])
    |> apply_filter(:level, opts[:level])
    |> apply_filter(:parent_id, opts[:parent_id])
    |> apply_filter(:blocked, opts[:blocked])
    |> apply_filter(:search, opts[:search])
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  defp apply_filter(query, :project_id, nil), do: query

  defp apply_filter(query, :project_id, project_id) do
    where(query, [t], t.project_id == ^project_id)
  end

  defp apply_filter(query, :level, nil), do: query

  defp apply_filter(query, :level, level) do
    where(query, [t], t.level == ^level)
  end

  defp apply_filter(query, :parent_id, nil), do: query

  defp apply_filter(query, :parent_id, parent_id) do
    from(t in query,
      join: h in Sacrum.Repo.Schemas.TaskHierarchy,
      on: h.child_id == t.id,
      where: h.parent_id == ^parent_id
    )
  end

  defp apply_filter(query, :blocked, nil), do: query

  defp apply_filter(query, :blocked, false) do
    # Exclude tasks that have incomplete (non-completed) dependencies
    from(t in query,
      where:
        t.id not in subquery(
          from(d in TaskDependency,
            join: dep in Task,
            on: dep.id == d.depends_on_id,
            where: is_nil(dep.completed_at),
            select: d.task_id,
            distinct: true
          )
        )
    )
  end

  defp apply_filter(query, :blocked, _), do: query

  defp apply_filter(query, :search, nil), do: query

  defp apply_filter(query, :search, term) do
    pattern = "%#{term}%"
    where(query, [t], ilike(t.title, ^pattern) or ilike(t.description, ^pattern))
  end

  def insert(%Project{id: project_id}, attrs), do: insert(project_id, attrs)

  def insert(project_id, attrs) when is_binary(project_id) do
    %Task{project_id: project_id}
    |> Task.create_changeset(attrs)
    |> Repo.insert()
  end

  def update(%Task{} = task, attrs) do
    task
    |> Task.update_changeset(attrs)
    |> Repo.update()
  end

  def delete(%Task{} = task), do: Repo.delete(task)
end
