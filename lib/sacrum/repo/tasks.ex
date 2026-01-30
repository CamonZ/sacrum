defmodule Sacrum.Repo.Tasks do
  @moduledoc """
  CRUD operations for tasks, scoped to a project.

  ## Error Contract

  - `get/1` returns `{:ok, task}` or `{:error, :not_found}`
  - `get_by_short_id/1` returns `{:ok, task}` or `{:error, :not_found}`
  - `insert/2` returns `{:ok, task}` or `{:error, changeset}`
  - `update/2` returns `{:ok, task}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, task}` or `{:error, changeset}`

  ## Domain-Specific Errors

  `update/2` may return `{:error, changeset}` with validation errors for:
  - Invalid section IDs provided in the `:sections` field

  ## Preload Strategy

  The `get/1` and `get_by_short_id/1` functions automatically preload the `:sections`
  association. The `list_tasks/1` function also preloads `:sections`. Other functions
  leave preloading to callers.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.TaskDependency
  alias Sacrum.Repo.Broadcaster

  def get(id) do
    case Repo.get(Task, id) do
      nil -> {:error, :not_found}
      task -> {:ok, Repo.preload(task, :sections)}
    end
  end

  def get!(id), do: Repo.get!(Task, id) |> Repo.preload(:sections)

  def get_by_short_id(short_id) do
    case Repo.get_by(Task, short_id: short_id) do
      nil -> {:error, :not_found}
      task -> {:ok, Repo.preload(task, :sections)}
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
    - `:status` - filter by workflow step name
    - `:tags` - filter by tags (any match)
    - `:root_only` - when true, exclude tasks that have a parent
    - `:workflow_id` - filter by assigned workflow
  """
  def list_tasks(opts \\ []) do
    Task
    |> apply_filter(:project_id, opts[:project_id])
    |> apply_filter(:level, opts[:level])
    |> apply_filter(:parent_id, opts[:parent_id])
    |> apply_filter(:blocked, opts[:blocked])
    |> apply_filter(:search, opts[:search])
    |> apply_filter(:status, opts[:status])
    |> apply_filter(:tags, opts[:tags])
    |> apply_filter(:root_only, opts[:root_only])
    |> apply_filter(:workflow_id, opts[:workflow_id])
    |> order_by([t], asc: t.inserted_at)
    |> preload(:sections)
    |> Repo.all()
  end

  @doc """
  Returns root tasks (no parent) with no incomplete blockers for a project.
  These are the highest-level actionable items ready for work.
  """
  def ready(project_id) do
    list_tasks(project_id: project_id, root_only: true, blocked: false)
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

  defp apply_filter(query, :status, nil), do: query

  defp apply_filter(query, :status, step_name) do
    from(t in query,
      join: ws in Sacrum.Repo.Schemas.WorkflowStep,
      on: ws.id == t.current_step_id,
      where: ws.name == ^step_name
    )
  end

  defp apply_filter(query, :tags, nil), do: query

  defp apply_filter(query, :tags, tags) when is_list(tags) do
    where(query, [t], fragment("? && ?", t.tags, ^tags))
  end

  defp apply_filter(query, :root_only, nil), do: query
  defp apply_filter(query, :root_only, false), do: query

  defp apply_filter(query, :root_only, true) do
    from(t in query,
      where:
        t.id not in subquery(
          from(h in Sacrum.Repo.Schemas.TaskHierarchy,
            select: h.child_id
          )
        )
    )
  end

  defp apply_filter(query, :workflow_id, nil), do: query

  defp apply_filter(query, :workflow_id, workflow_id) do
    where(query, [t], t.workflow_id == ^workflow_id)
  end

  def insert(%Project{id: project_id}, attrs), do: insert(project_id, attrs)

  def insert(project_id, attrs) when is_binary(project_id) do
    %Task{project_id: project_id}
    |> Task.create_changeset(attrs)
    |> Repo.insert()
    |> preload_sections()
    |> Broadcaster.broadcast(:task_created, :project)
  end

  def update(%Task{} = task, attrs) do
    task = Repo.preload(task, :sections)

    with :ok <- validate_section_ownership(task, attrs),
         {:ok, updated_task} <- do_update_task(task, attrs),
         :ok <- maybe_update_parent(updated_task, attrs),
         :ok <- maybe_update_dependencies(updated_task, attrs) do
      Broadcaster.broadcast({:ok, updated_task}, :task_updated, :project)
    end
  end

  defp do_update_task(task, attrs) do
    task
    |> Task.update_changeset(attrs)
    |> Repo.update()
    |> preload_sections()
  end

  defp maybe_update_parent(task, %{"parent_id" => nil}) do
    case Sacrum.Repo.TaskHierarchy.remove_parent(task) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  defp maybe_update_parent(task, %{"parent_id" => parent_id}) do
    case Repo.get(Sacrum.Repo.Schemas.Task, parent_id) do
      nil ->
        {:error, :not_found}

      parent ->
        # Remove existing parent first if any
        Sacrum.Repo.TaskHierarchy.remove_parent(task)

        case Sacrum.Repo.TaskHierarchy.set_parent(task, parent) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp maybe_update_parent(_task, _attrs), do: :ok

  defp maybe_update_dependencies(task, %{"depends_on_ids" => ids}) when is_list(ids) do
    # Get current dependencies
    current = Sacrum.Repo.TaskDependencies.get_direct_blockers(task)
    current_ids = MapSet.new(Enum.map(current, & &1.id))
    desired_ids = MapSet.new(ids)

    # Remove dependencies that are no longer desired
    to_remove = MapSet.difference(current_ids, desired_ids)

    for id <- to_remove do
      case Repo.get(Sacrum.Repo.Schemas.Task, id) do
        nil -> :ok
        dep -> Sacrum.Repo.TaskDependencies.remove_dependency(task, dep)
      end
    end

    # Add new dependencies
    to_add = MapSet.difference(desired_ids, current_ids)

    results =
      for id <- to_add do
        case Repo.get(Sacrum.Repo.Schemas.Task, id) do
          nil -> {:error, :not_found}
          dep -> Sacrum.Repo.TaskDependencies.add_dependency(task, dep)
        end
      end

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        :ok

      {:error, :different_projects} ->
        {:error, :unprocessable_entity, "depends_on_ids must be in the same project"}

      {:error, :self_dependency} ->
        {:error, :unprocessable_entity, "a task cannot depend on itself"}

      {:error, :circular_dependency} ->
        {:error, :unprocessable_entity, "would create a circular dependency"}

      {:error, :not_found} ->
        {:error, :unprocessable_entity, "one or more dependencies not found"}

      error ->
        error
    end
  end

  defp maybe_update_dependencies(_task, _attrs), do: :ok

  def delete(%Task{} = task) do
    case Repo.delete(task) do
      {:ok, deleted_task} ->
        Broadcaster.broadcast_event(deleted_task, :task_deleted, :project)
        {:ok, deleted_task}

      error ->
        error
    end
  end

  defp validate_section_ownership(%Task{} = task, %{"sections" => sections})
       when is_list(sections) do
    existing_ids = MapSet.new(Enum.map(task.sections, &to_string(&1.id)))

    incoming_ids =
      sections
      |> Enum.map(& &1["id"])
      |> Enum.reject(&is_nil/1)
      |> MapSet.new(&to_string/1)

    foreign_ids = MapSet.difference(incoming_ids, existing_ids)

    if MapSet.size(foreign_ids) == 0 do
      :ok
    else
      changeset =
        task
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:sections, "contain IDs not belonging to this task")

      {:error, changeset}
    end
  end

  defp validate_section_ownership(_task, _attrs), do: :ok

  defp preload_sections({:ok, task}), do: {:ok, Repo.preload(task, :sections, force: true)}
  defp preload_sections(error), do: error
end
