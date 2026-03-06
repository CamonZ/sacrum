defmodule Sacrum.Repo.Tasks do
  @moduledoc """
  CRUD operations for tasks, scoped to a project.

  ## Error Contract

  - `insert/2` returns `{:ok, task}` or `{:error, changeset}`
  - `update/2` returns `{:ok, task}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, task}` or `{:error, changeset}`

  ## Domain-Specific Errors

  `update/2` may return `{:error, changeset}` with validation errors for:
  - Invalid section IDs provided in the `:sections` field
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Task

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskDependency
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.TaskHierarchy

  @doc """
  Lists tasks with optional filters.

  Options:
    - `:project_id` - filter by project
    - `:user_id` - filter by user
    - `:level` - filter by task level
    - `:parent_id` - filter by parent task (via hierarchy)
    - `:blocked` - when false, exclude tasks with incomplete dependencies
    - `:search` - text search on title/description
    - `:status` - filter by workflow step name
    - `:tags` - filter by tags (any match)
    - `:root_only` - when true, exclude tasks that have a parent
    - `:workflow_id` - filter by assigned workflow
  """
  @spec list_tasks(keyword()) :: [Task.t()]
  def list_tasks(opts) do
    Task
    |> apply_filters(opts)
    |> apply_task_preloads(opts)
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns tasks that are not completed and have no
  incomplete blockers for a project.
  """
  @spec ready(String.t(), String.t()) :: [Task.t()]
  def ready(project_id, user_id) do
    list_tasks(
      conditions: [
        project_id: project_id,
        user_id: user_id,
        blocked: false,
        completed: false,
        step_entered: true
      ]
    )
  end

  defp apply_task_preloads(query, opts) do
    preloads = Keyword.get(opts, :preloads, [])
    apply_join_preloads(query, preloads)
  end

  defp apply_join_preloads(query, []), do: query

  defp apply_join_preloads(query, preloads) do
    Enum.reduce(preloads, query, fn assoc, q ->
      q
      |> join(:left, [t], a in assoc(t, ^assoc), as: ^assoc)
      |> preload([{^assoc, a}], [{^assoc, a}])
    end)
  end

  defp apply_filters(query, opts) do
    opts
    |> Keyword.get(:conditions)
    |> Enum.reduce(query, fn {key, value}, acc -> apply_filter(acc, key, value) end)
  end

  defp apply_filter(query, :user_id, nil), do: query

  defp apply_filter(query, :user_id, user_id) do
    where(query, [t], t.user_id == ^user_id)
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
    where(query, [t], t.parent_id == ^parent_id)
  end

  defp apply_filter(query, :completed, nil), do: query

  defp apply_filter(query, :completed, false) do
    where(query, [t], is_nil(t.completed_at))
  end

  defp apply_filter(query, :completed, true) do
    where(query, [t], not is_nil(t.completed_at))
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
    where(query, [t], is_nil(t.parent_id))
  end

  defp apply_filter(query, :workflow_id, nil), do: query

  defp apply_filter(query, :workflow_id, workflow_id) do
    where(query, [t], t.workflow_id == ^workflow_id)
  end

  defp apply_filter(query, :step_entered, nil), do: query
  defp apply_filter(query, :step_entered, false), do: query

  defp apply_filter(query, :step_entered, true) do
    latest_exec_query =
      from(se in StepExecution,
        distinct: se.task_id,
        order_by: [asc: se.task_id, desc: se.inserted_at],
        select: %{task_id: se.task_id, status: se.status}
      )

    from(t in query,
      left_join: le in subquery(latest_exec_query),
      on: le.task_id == t.id,
      where: is_nil(t.workflow_id) or le.status == "entered"
    )
  end

  @spec insert(Project.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Project{id: project_id, user_id: user_id}, attrs) when is_binary(user_id) do
    insert(project_id, user_id, attrs)
  end

  def insert(%Project{id: project_id}, attrs) do
    %Task{project_id: project_id}
    |> Task.create_changeset(attrs)
    |> Repo.insert()
    |> preload_sections()
    |> Broadcaster.broadcast(:task_created, :project)
  end

  @spec insert(String.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def insert(project_id, attrs) when is_binary(project_id) and is_map(attrs) do
    %Task{project_id: project_id}
    |> Task.create_changeset(attrs)
    |> Repo.insert()
    |> preload_sections()
    |> Broadcaster.broadcast(:task_created, :project)
  end

  defoverridable insert: 2

  @spec insert(String.t(), String.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def insert(project_id, user_id, attrs) when is_binary(project_id) and is_binary(user_id) do
    %Task{project_id: project_id, user_id: user_id}
    |> Task.create_changeset(attrs)
    |> Repo.insert()
    |> preload_sections()
    |> Broadcaster.broadcast(:task_created, :project)
  end

  @spec update(Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update(%Task{} = task, attrs) do
    task = Repo.preload(task, :sections)

    with :ok <- validate_section_ownership(task, attrs),
         {:ok, updated_task} <- do_update_task(task, attrs),
         {:ok, updated_task} <- maybe_update_parent(updated_task, attrs),
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
    case TaskHierarchy.remove_parent(task) do
      {:ok, updated} -> {:ok, updated}
      {:error, :not_found} -> {:ok, task}
      error -> error
    end
  end

  defp maybe_update_parent(task, %{"parent_id" => parent_id}) do
    case Repo.get(Task, parent_id) do
      nil ->
        {:error, :not_found}

      parent ->
        TaskHierarchy.set_parent(task, parent)
    end
  end

  defp maybe_update_parent(task, _attrs), do: {:ok, task}

  defp maybe_update_dependencies(task, %{"depends_on_ids" => ids}) when is_list(ids) do
    current = TaskDependencies.get_direct_blockers(task)
    current_ids = MapSet.new(Enum.map(current, & &1.id))
    desired_ids = MapSet.new(ids)

    remove_stale_dependencies(task, MapSet.difference(current_ids, desired_ids))
    to_add = MapSet.difference(desired_ids, current_ids)
    results = add_new_dependencies(to_add, task)
    translate_dependency_error(results)
  end

  defp maybe_update_dependencies(_task, _attrs), do: :ok

  defp remove_stale_dependencies(task, to_remove) do
    for id <- to_remove do
      case Repo.get(Task, id) do
        nil -> :ok
        dep -> TaskDependencies.remove_dependency(task, dep)
      end
    end
  end

  defp add_new_dependencies(to_add, task) do
    for id <- to_add do
      case Repo.get(Task, id) do
        nil -> {:error, :not_found}
        dep -> TaskDependencies.add_dependency(task, dep)
      end
    end
  end

  defp translate_dependency_error(results) do
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

  @spec delete(Task.t(), keyword()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Task{} = task, opts \\ []) do
    cascade = Keyword.get(opts, :cascade, true)

    unless cascade do
      Repo.update_all(
        from(t in Task, where: t.parent_id == ^task.id),
        set: [parent_id: nil]
      )
    end

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
