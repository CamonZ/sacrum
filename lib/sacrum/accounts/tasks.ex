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
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.TaskHierarchy
  alias Sacrum.Repo.Tasks, as: TasksRepo

  @doc """
  Find a task by UUID or short_id within a user's scope.
  """
  @spec find(String.t(), String.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def find(user_id, id) when is_binary(user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} ->
        get_by(user_id, conditions: [id: id], preloads: [:parent])

      :error ->
        get_by(user_id, conditions: [short_id: id], preloads: [:parent])
    end
  end

  @spec resolve_short_id(String.t(), String.t(), String.t()) ::
          {:ok, Task.t()}
          | {:error, :not_found | :invalid_prefix}
          | {:error, {:ambiguous, [String.t()]}}
  def resolve_short_id(user_id, project_id, prefix) when is_binary(user_id) do
    TasksRepo.find_by_uuid_prefix(prefix, project_id, user_id)
  end

  @doc """
  List tasks with optional filters for a user.

  Options:
    - `:project_id` - filter by project
    - `:level` - filter by task level
    - `:parent_id` - filter by parent task
    - `:blocked` - when false, exclude tasks with incomplete dependencies
    - `:search` - text search on title, description, or UUID prefix
    - `:status` - compatibility filter over persisted task status. New derivations
      write `"ready"` or `"done"`; use TaskRun queries for active run lifecycle.
    - `:tags` - filter by tags
    - `:root_only` - when true, exclude tasks with parents
    - `:workflow_id` - filter by assigned workflow
  """
  @spec list_tasks(String.t(), keyword()) :: [Task.t()]
  def list_tasks(user_id, opts \\ []) when is_binary(user_id) do
    conditions = [{:user_id, user_id} | Keyword.get(opts, :conditions, [])]
    TasksRepo.list_tasks(Keyword.put(opts, :conditions, conditions))
  end

  @doc """
  Returns tasks with no incomplete blockers for a project.
  These are the actionable items ready for work.
  """
  @spec ready(String.t(), String.t()) :: [Task.t()]
  def ready(user_id, project_id) when is_binary(user_id) and is_binary(project_id) do
    TasksRepo.ready(project_id, user_id)
  end

  @doc """
  Insert a new task for a user within a project.
  Accepts either (project_struct, attrs) or (user_id, project_id, attrs).

  If no workflow_id and current_step_id are provided in attrs, they are
  auto-assigned from the project's default Backlog workflow. An error is
  raised if no default workflow exists.
  """
  @spec insert(map(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def insert(%{id: project_id, user_id: user_id}, attrs) do
    insert(user_id, project_id, attrs)
  end

  @spec insert(String.t(), String.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, project_id, attrs) when is_binary(user_id) and is_binary(project_id) do
    TasksRepo.insert(project_id, user_id, attrs)
  end

  @doc """
  Update a task with support for section, parent, and dependency management.
  """
  @spec update(Task.t(), map()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def update(%Task{} = task, attrs) do
    task = Repo.preload(task, :sections)

    with :ok <- validate_section_ownership(task, attrs),
         {:ok, updated_task} <- do_update_task(task, attrs),
         {:ok, updated_task} <- maybe_update_parent(updated_task, attrs),
         :ok <- maybe_update_dependencies(updated_task, attrs) do
      {:ok, updated_task}
    end
  end

  @doc """
  Delete a task.
  """
  @spec delete(Task.t(), keyword()) :: {:ok, Task.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Task{} = task, opts \\ []) do
    TasksRepo.delete(task, opts)
  end

  defp do_update_task(task, attrs) do
    task
    |> Task.update_changeset(attrs)
    |> TasksRepo.update()
    |> preload_sections()
  end

  defp maybe_update_parent(task, attrs) do
    parent_id = Map.get(attrs, "parent_id", Map.get(attrs, :parent_id, :not_set))

    case parent_id do
      :not_set ->
        {:ok, task}

      nil ->
        case TaskHierarchy.remove_parent(task) do
          {:ok, updated} -> {:ok, updated}
          {:error, :not_found} -> {:ok, task}
          error -> error
        end

      id ->
        case Repo.get(Task, id) do
          nil -> {:error, :not_found}
          parent -> TaskHierarchy.set_parent(task, parent)
        end
    end
  end

  defp maybe_update_dependencies(task, attrs)
       when is_map_key(attrs, "depends_on_ids") or is_map_key(attrs, :depends_on_ids) do
    ids = Map.get(attrs, "depends_on_ids", Map.get(attrs, :depends_on_ids))
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

  defp validate_section_ownership(%Task{} = task, attrs) do
    sections = Map.get(attrs, "sections", Map.get(attrs, :sections))

    case sections do
      nil ->
        :ok

      sections when is_list(sections) ->
        existing_ids = MapSet.new(Enum.map(task.sections, &to_string(&1.id)))

        incoming_ids =
          sections
          |> Enum.map(&(Map.get(&1, "id") || Map.get(&1, :id)))
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

      _ ->
        :ok
    end
  end

  defp preload_sections({:ok, task}), do: {:ok, Repo.preload(task, :sections, force: true)}
  defp preload_sections(error), do: error
end
