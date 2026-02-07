defmodule Sacrum.Accounts.Tasks do
  @moduledoc """
  User-scoped task operations with business logic.

  All operations are scoped to a specific user. Includes domain-specific
  logic for task dependencies, hierarchy, and section management.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.Tasks,
    preloads: [:sections],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo
  alias Sacrum.Repo.Tasks, as: TasksRepo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Broadcaster

  @doc """
  Find a task by UUID or short_id within a user's scope.
  """
  def find(user_id, id) when is_binary(user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} ->
        get_by(user_id, conditions: [id: id], preloads: [:parent])

      :error ->
        get_by(user_id, conditions: [short_id: id], preloads: [:parent])
    end
  end

  @doc """
  List tasks with optional filters for a user.

  Options:
    - `:project_id` - filter by project
    - `:level` - filter by task level
    - `:parent_id` - filter by parent task
    - `:blocked` - when false, exclude tasks with incomplete dependencies
    - `:search` - text search on title/description
    - `:status` - filter by workflow step name
    - `:tags` - filter by tags
    - `:root_only` - when true, exclude tasks with parents
    - `:workflow_id` - filter by assigned workflow
  """
  def list_tasks(user_id, opts \\ []) when is_binary(user_id) do
    conditions = [{:user_id, user_id} | Keyword.get(opts, :conditions, [])]
    TasksRepo.list_tasks(Keyword.put(opts, :conditions, conditions))
  end

  @doc """
  Returns root tasks (no parent) with no incomplete blockers for a project.
  These are the highest-level actionable items ready for work.
  """
  def ready(user_id, project_id) when is_binary(user_id) and is_binary(project_id) do
    TasksRepo.ready(project_id, user_id)
  end

  @doc """
  Insert a new task for a user within a project.
  Accepts either (project_struct, attrs) or (user_id, project_id, attrs).
  """
  def insert(%{id: project_id, user_id: user_id}, attrs) do
    insert(user_id, project_id, attrs)
  end

  def insert(user_id, project_id, attrs) when is_binary(user_id) and is_binary(project_id) do
    %Task{project_id: project_id, user_id: user_id}
    |> Task.create_changeset(attrs)
    |> TasksRepo.insert()
    |> preload_sections()
    |> maybe_assign_default_workflow(project_id)
    |> Broadcaster.broadcast(:task_created, :project)
  end

  @doc """
  Update a task with support for section, parent, and dependency management.
  """
  def update(%Task{} = task, attrs) do
    task = Repo.preload(task, :sections)

    with :ok <- validate_section_ownership(task, attrs),
         {:ok, updated_task} <- do_update_task(task, attrs),
         {:ok, updated_task} <- maybe_update_parent(updated_task, attrs),
         :ok <- maybe_update_dependencies(updated_task, attrs) do
      Broadcaster.broadcast({:ok, updated_task}, :task_updated, :project)
    end
  end

  @doc """
  Delete a task.
  """
  def delete(%Task{} = task, opts \\ []) do
    case TasksRepo.delete(task, opts) do
      {:ok, deleted_task} ->
        Broadcaster.broadcast_event(deleted_task, :task_deleted, :project)
        {:ok, deleted_task}

      error ->
        error
    end
  end

  defp do_update_task(task, attrs) do
    task
    |> Task.update_changeset(attrs)
    |> TasksRepo.update()
    |> preload_sections()
  end

  defp maybe_update_parent(task, %{"parent_id" => nil}) do
    case Sacrum.Repo.TaskHierarchy.remove_parent(task) do
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
        Sacrum.Repo.TaskHierarchy.set_parent(task, parent)
    end
  end

  defp maybe_update_parent(task, _attrs), do: {:ok, task}

  defp maybe_update_dependencies(task, %{"depends_on_ids" => ids}) when is_list(ids) do
    # Get current dependencies
    current = Sacrum.Repo.TaskDependencies.get_direct_blockers(task)
    current_ids = MapSet.new(Enum.map(current, & &1.id))
    desired_ids = MapSet.new(ids)

    # Remove dependencies that are no longer desired
    to_remove = MapSet.difference(current_ids, desired_ids)

    for id <- to_remove do
      case Repo.get(Task, id) do
        nil -> :ok
        dep -> Sacrum.Repo.TaskDependencies.remove_dependency(task, dep)
      end
    end

    # Add new dependencies
    to_add = MapSet.difference(desired_ids, current_ids)

    results =
      for id <- to_add do
        case Repo.get(Task, id) do
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

  defp maybe_assign_default_workflow({:ok, %Task{workflow_id: nil} = task}, project_id) do
    case find_default_workflow(project_id) do
      nil ->
        {:ok, task}

      workflow ->
        case Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow) do
          {:ok, task} -> {:ok, task}
          {:error, _} -> {:ok, task}
        end
    end
  end

  defp maybe_assign_default_workflow(result, _project_id), do: result

  defp find_default_workflow(project_id) do
    import Ecto.Query

    from(w in Workflow,
      where: w.project_id == ^project_id and w.is_default == true,
      limit: 1
    )
    |> Repo.one()
  end

  defp preload_sections({:ok, task}), do: {:ok, Repo.preload(task, :sections, force: true)}
  defp preload_sections(error), do: error
end
