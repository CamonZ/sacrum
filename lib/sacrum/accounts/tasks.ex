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

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.TaskHierarchy
  alias Sacrum.Repo.Tasks, as: TasksRepo
  alias Sacrum.Repo.TaskSections

  @doc """
  Find a task by UUID within a user's scope.
  """
  @spec find(String.t(), String.t()) :: {:ok, Task.t()} | {:error, :not_found}
  def find(user_id, id) when is_binary(user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} ->
        get_by(user_id, conditions: [id: id], preloads: [:parent])

      :error ->
        {:error, :not_found}
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

    case validate_section_ownership(task, attrs) do
      :ok -> run_task_update_transaction(task, attrs)
      error -> error
    end
  end

  @doc """
  Adds a direct blocker dependency for a task.
  """
  @spec add_dependency(Task.t(), Task.t()) ::
          {:ok, Sacrum.Repo.Schemas.TaskDependency.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, atom()}
  def add_dependency(%Task{} = task, %Task{} = depends_on) do
    TaskDependencies.add_dependency(task, depends_on)
  end

  @doc """
  Removes a direct blocker dependency from a task.
  """
  @spec remove_dependency(Task.t(), Task.t()) ::
          {:ok, Sacrum.Repo.Schemas.TaskDependency.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, atom()}
  def remove_dependency(%Task{} = task, %Task{} = depends_on) do
    TaskDependencies.remove_dependency(task, depends_on)
  end

  @doc """
  Replaces the direct blocker dependency set for a task atomically.
  """
  @spec sync_dependencies(Task.t(), [String.t()]) ::
          {:ok, Task.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, String.t()}
  def sync_dependencies(%Task{} = task, depends_on_ids) when is_list(depends_on_ids) do
    case reconcile_dependencies(task, depends_on_ids) do
      :ok -> {:ok, task}
      error -> error
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
    task_attrs = Map.drop(attrs, ["sections", :sections, "section_deletions", :section_deletions])
    section_attrs = Map.get(attrs, "sections", Map.get(attrs, :sections, []))

    section_deletions =
      Map.get(attrs, "section_deletions", Map.get(attrs, :section_deletions, []))

    with {:ok, updated_task} <- update_task_fields(task, task_attrs),
         :ok <- delete_task_sections(task, section_deletions),
         :ok <- upsert_task_sections(task, section_attrs) do
      {:ok, updated_task}
    end
  end

  defp unwrap_task_update_transaction({:ok, updated_task}), do: {:ok, updated_task}
  defp unwrap_task_update_transaction({:error, {:error, _} = error}), do: error
  defp unwrap_task_update_transaction({:error, error}), do: error

  defp run_task_update_transaction(task, attrs) do
    transaction_result = Repo.transaction(fn -> commit_or_rollback_task_update(task, attrs) end)
    unwrap_task_update_transaction(transaction_result)
  end

  defp commit_or_rollback_task_update(task, attrs) do
    case do_atomic_task_update(task, attrs) do
      {:ok, updated_task} -> updated_task
      error -> Repo.rollback(error)
    end
  end

  defp do_atomic_task_update(task, attrs) do
    with {:ok, updated_task} <- do_update_task(task, attrs),
         {:ok, updated_task} <- maybe_update_parent(updated_task, attrs),
         :ok <- maybe_update_dependencies(updated_task, attrs) do
      {:ok, Repo.preload(updated_task, :sections, force: true)}
    end
  end

  defp update_task_fields(task, attrs) do
    task
    |> Task.update_changeset(attrs)
    |> TasksRepo.update()
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
        case scoped_task(task, id) do
          nil -> {:error, :not_found}
          parent -> TaskHierarchy.set_parent(task, parent)
        end
    end
  end

  defp maybe_update_dependencies(task, attrs)
       when is_map_key(attrs, "depends_on_ids") or is_map_key(attrs, :depends_on_ids) do
    ids = Map.get(attrs, "depends_on_ids", Map.get(attrs, :depends_on_ids))
    reconcile_dependencies(task, ids)
  end

  defp maybe_update_dependencies(_task, _attrs), do: :ok

  defp reconcile_dependencies(task, ids) do
    result =
      if Repo.in_transaction?() do
        do_reconcile_dependencies(task, ids)
      else
        with_dependency_transaction(task, ids)
      end

    case result do
      :ok -> :ok
      error -> translate_dependency_error(error)
    end
  end

  defp with_dependency_transaction(task, ids) do
    transaction_result = Repo.transaction(fn -> commit_or_rollback_dependencies(task, ids) end)

    case transaction_result do
      {:ok, :ok} -> :ok
      {:error, error} -> error
    end
  end

  defp commit_or_rollback_dependencies(task, ids) do
    case do_reconcile_dependencies(task, ids) do
      :ok -> :ok
      error -> Repo.rollback(error)
    end
  end

  defp do_reconcile_dependencies(task, ids) do
    lock_task(task)

    current = TaskDependencies.get_direct_blockers(task)
    current_ids = MapSet.new(Enum.map(current, & &1.id))
    desired_ids = MapSet.new(ids)

    case remove_stale_dependencies(task, MapSet.difference(current_ids, desired_ids)) do
      :ok -> add_new_dependencies(MapSet.difference(desired_ids, current_ids), task)
      error -> error
    end
  end

  defp lock_task(task) do
    Repo.one(
      from t in Task,
        where:
          t.id == ^task.id and t.project_id == ^task.project_id and t.user_id == ^task.user_id,
        lock: "FOR UPDATE",
        select: t.id
    )

    :ok
  end

  defp scoped_task(task, id) do
    Repo.get_by(Task, id: id, project_id: task.project_id, user_id: task.user_id)
  end

  defp translate_dependency_error(error) do
    case error do
      :ok ->
        :ok

      {:error, :different_projects} ->
        {:error, "one or more dependencies not found"}

      {:error, :self_dependency} ->
        {:error, "a task cannot depend on itself"}

      {:error, :circular_dependency} ->
        {:error, "would create a circular dependency"}

      {:error, :not_found} ->
        {:error, "one or more dependencies not found"}

      error ->
        error
    end
  end

  defp remove_stale_dependencies(task, to_remove) do
    Enum.reduce_while(to_remove, :ok, fn id, :ok ->
      case remove_dependency_by_id(task, id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp add_new_dependencies(to_add, task) do
    Enum.reduce_while(to_add, :ok, fn id, :ok ->
      case add_dependency_by_id(task, id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_dependency_by_id(task, id) do
    case scoped_task(task, id) do
      nil -> :ok
      dep -> remove_existing_dependency(task, dep)
    end
  end

  defp remove_existing_dependency(task, dep) do
    case TaskDependencies.remove_dependency(task, dep) do
      {:ok, _dependency} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  defp add_dependency_by_id(task, id) do
    case scoped_task(task, id) do
      nil -> {:error, :not_found}
      dep -> add_existing_dependency(task, dep)
    end
  end

  defp add_existing_dependency(task, dep) do
    case TaskDependencies.add_dependency(task, dep) do
      {:ok, _dependency} -> :ok
      error -> error
    end
  end

  defp validate_section_ownership(%Task{} = task, attrs) do
    sections = Map.get(attrs, "sections", Map.get(attrs, :sections))
    deletion_ids = Map.get(attrs, "section_deletions", Map.get(attrs, :section_deletions, []))

    case sections do
      nil ->
        validate_section_ids(task, MapSet.new(), deletion_ids)

      sections when is_list(sections) ->
        existing_ids = MapSet.new(Enum.map(task.sections, &to_string(&1.id)))

        incoming_ids =
          sections
          |> Enum.map(&(Map.get(&1, "id") || Map.get(&1, :id)))
          |> Enum.reject(&is_nil/1)
          |> MapSet.new(&to_string/1)

        foreign_ids = MapSet.difference(incoming_ids, existing_ids)

        if MapSet.size(foreign_ids) == 0 do
          validate_section_ids(task, incoming_ids, deletion_ids)
        else
          changeset =
            task
            |> Ecto.Changeset.change()
            |> Ecto.Changeset.add_error(:sections, "contain IDs not belonging to this task")

          {:error, changeset}
        end

      _ ->
        validate_section_ids(task, MapSet.new(), deletion_ids)
    end
  end

  defp validate_section_ids(%Task{} = task, incoming_ids, deletion_ids)
       when is_list(deletion_ids) do
    existing_ids = MapSet.new(Enum.map(task.sections, &to_string(&1.id)))
    deletion_ids = MapSet.new(deletion_ids, &to_string/1)
    foreign_ids = MapSet.difference(deletion_ids, existing_ids)
    duplicate_ids = MapSet.intersection(incoming_ids, deletion_ids)

    cond do
      MapSet.size(foreign_ids) > 0 ->
        task
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:section_deletions, "contain IDs not belonging to this task")
        |> then(&{:error, &1})

      MapSet.size(duplicate_ids) > 0 ->
        task
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:sections, "cannot include IDs also listed for deletion")
        |> then(&{:error, &1})

      true ->
        :ok
    end
  end

  defp validate_section_ids(_task, _incoming_ids, _deletion_ids), do: :ok

  defp delete_task_sections(_task, []), do: :ok

  defp delete_task_sections(task, section_ids) do
    Enum.reduce_while(section_ids, :ok, fn section_id, :ok ->
      case find_task_section(task, section_id) do
        {:ok, section} -> continue_or_halt(TaskSections.delete(section))
        error -> {:halt, error}
      end
    end)
  end

  defp upsert_task_sections(_task, []), do: :ok

  defp upsert_task_sections(task, sections) do
    Enum.reduce_while(sections, :ok, fn attrs, :ok ->
      case upsert_task_section(task, attrs) do
        {:ok, _section} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp upsert_task_section(task, attrs) do
    case Map.get(attrs, "id", Map.get(attrs, :id)) do
      nil -> TaskSections.upsert(task, attrs)
      id -> update_task_section(task, id, attrs)
    end
  end

  defp update_task_section(task, section_id, attrs) do
    with {:ok, section} <- find_task_section(task, section_id) do
      TaskSections.update(section, Map.drop(attrs, ["id", :id]))
    end
  end

  defp find_task_section(task, section_id) do
    section =
      Enum.find(task.sections, fn section ->
        to_string(section.id) == to_string(section_id)
      end)

    case section do
      nil -> {:error, :not_found}
      section -> {:ok, section}
    end
  end

  defp continue_or_halt({:ok, _section}), do: {:cont, :ok}
  defp continue_or_halt(error), do: {:halt, error}
end
