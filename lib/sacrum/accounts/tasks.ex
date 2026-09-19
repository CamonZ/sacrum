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
  alias Sacrum.Repo.Schemas.TaskSection
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.Tasks, as: TasksRepo
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Tasks.Placement

  @dependency_scope_constraints [
    "task_dependencies_task_scope_fkey",
    "task_dependencies_depends_on_scope_fkey"
  ]

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

    case validate_section_changes(task, attrs) do
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

  defp run_task_update_transaction(task, attrs) do
    transaction_result = Repo.transaction(task_update_multi(task, attrs))
    unwrap_task_update_transaction(transaction_result)
  end

  defp unwrap_task_update_transaction({:ok, %{result: updated_task}}),
    do: {:ok, updated_task}

  defp unwrap_task_update_transaction({:error, _operation, reason, _changes}),
    do: {:error, reason}

  @dialyzer {:no_opaque, task_update_multi: 2}
  defp task_update_multi(task, attrs) do
    section_attrs = Map.get(attrs, :sections, [])
    section_deletions = Map.get(attrs, :section_deletions, []) || []

    Ecto.Multi.new()
    |> Placement.append_update(:placement, task, attrs)
    |> Ecto.Multi.run(:prepare_task, &prepare_task_update_step(&1, &2, task, attrs))
    |> Ecto.Multi.update(:task, &task_update_changeset/1)
    |> Ecto.Multi.delete_all(
      :delete_task_sections,
      from(
        section in TaskSection,
        where:
          section.task_id == ^task.id and section.project_id == ^task.project_id and
            section.user_id == ^task.user_id and section.id in ^section_deletions
      )
    )
    |> Ecto.Multi.run(
      :upsert_task_sections,
      &upsert_task_sections_step(&1, &2, task, section_attrs)
    )
    |> Ecto.Multi.run(:dependencies, &dependencies_step(&1, &2, attrs))
    |> Ecto.Multi.run(:result, &task_update_result/2)
  end

  defp prepare_task_update_step(_repo, %{placement: placement}, _task, attrs) do
    %{task: task_for_update, workspace: workspace} = placement

    task_attrs = Map.drop(attrs, [:sections, :section_deletions, :workspace, :worktree])

    task_attrs =
      if workspace == :not_set, do: task_attrs, else: Map.put(task_attrs, :workspace, workspace)

    {:ok, {task_for_update, task_attrs}}
  end

  defp task_update_changeset(%{prepare_task: {task_for_update, task_attrs}}) do
    Task.update_changeset(task_for_update, task_attrs)
  end

  defp upsert_task_sections_step(_repo, _changes, task, section_attrs) do
    case upsert_task_sections(task, section_attrs) do
      :ok -> {:ok, :ok}
      error -> error
    end
  end

  defp dependencies_step(_repo, %{task: updated_task}, attrs) do
    case maybe_update_dependencies(updated_task, attrs) do
      :ok -> {:ok, updated_task}
      error -> error
    end
  end

  defp task_update_result(_repo, %{dependencies: updated_task}) do
    {:ok, Repo.preload(updated_task, :sections, force: true)}
  end

  defp maybe_update_dependencies(task, attrs)
       when is_map_key(attrs, :depends_on_ids) do
    ids = Map.get(attrs, :depends_on_ids)
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

  defp translate_dependency_error(error) do
    case error do
      :ok ->
        :ok

      {:error, %Ecto.Changeset{} = changeset} ->
        if dependency_scope_error?(changeset) do
          {:error, "one or more dependencies not found"}
        else
          {:error, changeset}
        end

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

  defp dependency_scope_error?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {field, {_message, opts}} when field in [:task_id, :depends_on_id] ->
        opts[:constraint] == :foreign and
          to_string(opts[:constraint_name]) in @dependency_scope_constraints

      _error ->
        false
    end)
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
    remove_existing_dependency(task, dependency_reference(task, id))
  end

  defp remove_existing_dependency(task, dep) do
    case TaskDependencies.remove_dependency(task, dep) do
      {:ok, _dependency} -> :ok
      {:error, :not_found} -> :ok
      error -> error
    end
  end

  defp add_dependency_by_id(task, id) do
    add_existing_dependency(task, dependency_reference(task, id))
  end

  defp add_existing_dependency(task, dep) do
    case TaskDependencies.add_dependency(task, dep) do
      {:ok, _dependency} -> :ok
      error -> error
    end
  end

  defp validate_section_changes(%Task{} = task, attrs) do
    incoming_ids = section_ids(Map.get(attrs, :sections, []))
    deletion_ids = Map.get(attrs, :section_deletions, []) || []

    validate_section_ids(task, incoming_ids, deletion_ids)
  end

  @spec validate_section_ids(Task.t(), [String.t()], term()) ::
          :ok | {:error, Ecto.Changeset.t()}
  defp validate_section_ids(%Task{} = task, incoming_ids, deletion_ids)
       when is_list(deletion_ids) do
    existing_ids = Enum.map(task.sections, &to_string(&1.id))
    deletion_ids = Enum.map(deletion_ids, &to_string/1)
    foreign_ids = Enum.reject(deletion_ids, &(&1 in existing_ids))
    duplicate? = Enum.any?(deletion_ids, &(&1 in incoming_ids))

    cond do
      foreign_ids != [] ->
        task
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:section_deletions, "contain IDs not belonging to this task")
        |> then(&{:error, &1})

      duplicate? ->
        task
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:sections, "cannot include IDs also listed for deletion")
        |> then(&{:error, &1})

      true ->
        :ok
    end
  end

  defp validate_section_ids(_task, _incoming_ids, _deletion_ids), do: :ok

  defp section_ids(sections) when is_list(sections) do
    sections
    |> Enum.map(&Map.get(&1, :id))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
  end

  defp section_ids(_sections), do: []

  defp upsert_task_sections(_task, []), do: :ok

  defp upsert_task_sections(task, sections) do
    Enum.reduce_while(sections, :ok, fn attrs, :ok ->
      case TaskSections.upsert(task, attrs) do
        {:ok, _section} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp dependency_reference(%Task{} = task, id) do
    %Task{id: id, project_id: task.project_id, user_id: task.user_id}
  end
end
