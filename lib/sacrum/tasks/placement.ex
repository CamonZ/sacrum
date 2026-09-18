defmodule Sacrum.Tasks.Placement do
  @moduledoc """
  Resolves and mutates the durable placement owned by a task.

  Placement is serialized by the task row. Queue-time assignment selects a
  connected, enrolled daemon, while dispatch validates the persisted owner.
  """

  import Ecto.Query

  alias Ecto.Multi
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Daemon, Task, TaskRun, TaskWorkspace}
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @type workspace_attrs :: map() | nil
  @type placement_update :: %{task: Task.t(), workspace: TaskWorkspace.t() | nil | :not_set}
  @active_statuses TaskRunStatus.active_statuses()

  @doc "Returns the locked, authorized workspace used by a dispatch entry point."
  @spec resolve_for_dispatch(Task.t()) :: {:ok, Task.t()} | {:error, atom()}
  def resolve_for_dispatch(%Task{} = task) do
    Repo.transaction(fn -> resolve_locked!(task) end)
  end

  @doc "Same resolver for callers already inside a transaction."
  @spec resolve_locked!(Task.t()) :: Task.t()
  def resolve_locked!(%Task{} = task) do
    locked_task = lock_task!(task)

    case Task.workspace_daemon(locked_task) do
      nil ->
        Repo.rollback(:workspace_required)

      daemon_id ->
        case authorized_daemon(locked_task.user_id, daemon_id) do
          {:ok, _daemon} ->
            task
            |> Map.merge(%{
              workspace: locked_task.workspace,
              workspace_daemon_id: locked_task.workspace_daemon_id
            })
            |> Task.with_legacy_worktree()

          {:error, reason} ->
            Repo.rollback(reason)
        end
    end
  end

  @doc "Validates a workspace on task creation without requiring a live daemon connection."
  @spec validate_workspace_owner(String.t() | nil, workspace_attrs()) :: :ok | {:error, atom()}
  def validate_workspace_owner(user_id, workspace) do
    case TaskWorkspace.normalize(workspace) do
      nil ->
        :ok

      %TaskWorkspace{daemon_id: nil} ->
        :ok

      %TaskWorkspace{daemon_id: daemon_id} ->
        validate_workspace_daemon(user_id, daemon_id)

      :invalid ->
        {:error, :invalid_workspace}
    end
  end

  defp validate_workspace_daemon(user_id, daemon_id) do
    with {:ok, daemon_id} <- cast_uuid(daemon_id),
         {:ok, _daemon} <- authorized_daemon(user_id, daemon_id) do
      :ok
    end
  end

  @doc "Appends placement validation and locking to a task update Multi."
  @spec append_update(Multi.t(), atom(), Task.t(), map()) :: Multi.t()
  def append_update(multi, name, %Task{} = task, attrs) do
    case workspace_update_attrs(attrs) do
      :not_set ->
        Multi.put(multi, name, %{task: task, workspace: :not_set})

      workspace_attrs ->
        Multi.run(multi, name, fn _repo, _changes ->
          prepare_workspace_update_result(task, workspace_attrs)
        end)
    end
  end

  @doc "Appends queue-time daemon selection and task placement to a Multi."
  @spec append_queue_assignment(Multi.t(), atom(), Task.t()) :: Multi.t()
  def append_queue_assignment(multi, name, %Task{} = task) do
    prepare_name = {name, :prepare}
    task_name = {name, :task}

    multi
    |> Multi.run(prepare_name, fn _repo, _changes ->
      case prepare_queue_assignment(task) do
        {:ok, locked_task, workspace} ->
          {:ok, %{task: locked_task, workspace: workspace}}

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> Multi.update(task_name, fn %{^prepare_name => %{task: locked_task, workspace: workspace}} ->
      Task.update_changeset(locked_task, %{workspace: workspace})
    end)
  end

  defp prepare_workspace_update_result(task, workspace_attrs) do
    case prepare_workspace_update(task, workspace_attrs) do
      {:ok, locked_task, workspace} ->
        {:ok, %{task: locked_task, workspace: workspace}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_workspace_update(%Task{} = task, attrs) do
    task = lock_task!(task)
    workspace = desired_workspace(task, attrs)

    with :ok <- validate_mutation_state(task, workspace),
         :ok <- validate_workspace_transition(task, workspace),
         :ok <- validate_workspace_owner(task.user_id, workspace) do
      {:ok, task, workspace}
    end
  end

  defp prepare_queue_assignment(%Task{} = task) do
    locked_task = lock_task!(task)

    case Task.workspace_daemon(locked_task) do
      nil ->
        with {:ok, daemon} <- select_connected_daemon(locked_task.user_id) do
          workspace =
            TaskWorkspace.normalize(%{
              daemon_id: daemon.id,
              worktree_path: Task.workspace_worktree(locked_task)
            })

          {:ok, locked_task, workspace}
        end

      daemon_id ->
        case authorized_daemon(locked_task.user_id, daemon_id) do
          {:ok, _daemon} ->
            {:ok, locked_task, TaskWorkspace.normalize(locked_task.workspace)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp workspace_update_attrs(attrs) do
    cond do
      Map.has_key?(attrs, :workspace) -> Map.get(attrs, :workspace)
      Map.has_key?(attrs, :worktree) -> %{worktree_path: Map.get(attrs, :worktree)}
      true -> :not_set
    end
  end

  defp validate_mutation_state(%Task{} = task, %TaskWorkspace{} = workspace) do
    active_run? =
      Repo.exists?(
        from tr in TaskRun,
          where: tr.task_id == ^task.id and tr.status in ^@active_statuses
      )

    if active_run? and current_workspace(task) != TaskWorkspace.normalize(workspace) do
      {:error, :workspace_locked}
    else
      :ok
    end
  end

  defp validate_mutation_state(%Task{} = task, nil) do
    validate_mutation_state(task, %TaskWorkspace{})
  end

  defp validate_workspace_transition(task, nil) do
    if is_nil(task.workspace), do: :ok, else: :ok
  end

  defp validate_workspace_transition(%Task{} = task, %TaskWorkspace{} = workspace) do
    current_daemon_id = Task.workspace_daemon(task)
    next_daemon_id = workspace.daemon_id
    current_path = Task.workspace_worktree(task)
    next_path = workspace.worktree_path

    cond do
      is_nil(next_daemon_id) ->
        :ok

      is_nil(current_daemon_id) and not is_nil(current_path) and is_nil(next_path) ->
        {:error, :legacy_worktree_decision_required}

      not is_nil(current_daemon_id) and current_daemon_id != next_daemon_id and is_nil(next_path) ->
        {:error, :worktree_decision_required}

      true ->
        :ok
    end
  end

  defp desired_workspace(%Task{} = task, attrs) do
    attrs
    |> workspace_attrs()
    |> normalize_desired_workspace(task)
  end

  defp workspace_attrs(nil), do: nil
  defp workspace_attrs(%{workspace: workspace}), do: workspace
  defp workspace_attrs(attrs) when is_map(attrs), do: attrs
  defp workspace_attrs(_attrs), do: nil

  defp normalize_desired_workspace(nil, _task), do: nil

  defp normalize_desired_workspace(%TaskWorkspace{} = workspace, _task) do
    TaskWorkspace.normalize(workspace)
  end

  defp normalize_desired_workspace(attrs, %Task{} = task) when is_map(attrs) do
    current_daemon_id = Task.workspace_daemon(task)
    requested_daemon_id = value_or_current(attrs, :daemon_id, current_daemon_id)

    TaskWorkspace.normalize(%{
      daemon_id: requested_daemon_id,
      worktree_path: desired_worktree_path(task, attrs, current_daemon_id, requested_daemon_id)
    })
  end

  defp desired_worktree_path(_task, attrs, _current_daemon_id, _requested_daemon_id)
       when is_map_key(attrs, :worktree_path),
       do: Map.get(attrs, :worktree_path)

  defp desired_worktree_path(task, attrs, current_daemon_id, requested_daemon_id) do
    if is_map_key(attrs, :daemon_id) and requested_daemon_id != current_daemon_id do
      nil
    else
      Task.workspace_worktree(task)
    end
  end

  defp value_or_current(attrs, key, current) do
    Map.get(attrs, key, current)
  end

  defp current_workspace(task) do
    TaskWorkspace.normalize(%{
      daemon_id: Task.workspace_daemon(task),
      worktree_path: Task.workspace_worktree(task)
    })
  end

  defp lock_task!(%Task{user_id: user_id, id: task_id}) do
    case Repo.one(
           from t in Task,
             where: t.id == ^task_id and t.user_id == ^user_id,
             lock: "FOR UPDATE"
         ) do
      %Task{} = task -> task
      _ -> Repo.rollback(:not_found)
    end
  end

  defp authorized_daemon(user_id, daemon_id) do
    case Repo.get_by(Daemon, id: daemon_id, user_id: user_id) do
      %Daemon{status: "active"} = daemon -> {:ok, daemon}
      %Daemon{} -> {:error, :daemon_not_enrolled}
      nil -> {:error, :daemon_not_found}
    end
  end

  defp select_connected_daemon(user_id) do
    connected_daemon_ids = Sacrum.DaemonConnectionRegistry.connected_daemon_ids()

    if connected_daemon_ids == [] do
      {:error, :daemon_unavailable}
    else
      query =
        from d in Daemon,
          where:
            d.user_id == ^user_id and
              d.status == "active" and
              d.id in ^connected_daemon_ids,
          order_by: [asc: d.id],
          limit: 1

      case Repo.one(query) do
        %Daemon{} = daemon -> {:ok, daemon}
        nil -> {:error, :daemon_unavailable}
      end
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :daemon_not_found}
    end
  end
end
