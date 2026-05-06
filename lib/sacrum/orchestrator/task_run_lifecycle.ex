defmodule Sacrum.Orchestrator.TaskRunLifecycle do
  @moduledoc """
  Shared TaskRun lifecycle operations for orchestration paths.

  This module intentionally delegates status meaning to `Sacrum.TaskRuns.Status`
  so the orchestrator does not grow a second run lifecycle contract.
  """

  alias Sacrum.Accounts.TaskRuns
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Task, TaskRun}
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @spec get_or_create_root_run(Task.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  def get_or_create_root_run(%Task{} = task) do
    case TaskRuns.get_active_for_task(task.user_id, task.id) do
      {:ok, %TaskRun{} = task_run} -> validate_dispatchable(task_run)
      {:error, :not_found} -> create_root_run(task)
    end
  end

  @spec create_root_run(Task.t()) :: {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def create_root_run(%Task{} = task) do
    TaskRuns.insert(task.user_id, task.project_id, task.id, %{status: :queued})
  end

  @spec get_or_create_child_run(Task.t(), TaskRun.t(), String.t()) ::
          {:ok, TaskRun.t()} | {:error, term()}
  def get_or_create_child_run(
        %Task{} = child,
        %TaskRun{} = parent_task_run,
        triggered_by_step_execution_id
      )
      when is_binary(triggered_by_step_execution_id) do
    case TaskRuns.get_active_for_task(child.user_id, child.id) do
      {:ok, %TaskRun{} = task_run} ->
        reconcile_child_run(task_run, parent_task_run, triggered_by_step_execution_id)

      {:error, :not_found} ->
        create_child_run(child, parent_task_run, triggered_by_step_execution_id)
    end
  end

  @spec validate_dispatchable(TaskRun.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  def validate_dispatchable(%TaskRun{} = task_run) do
    if TaskRunStatus.stoppable?(task_run.status),
      do: {:ok, task_run},
      else: {:error, {:task_run_not_dispatchable, task_run.status}}
  end

  @spec fetch_active_for_task(binary()) :: {:ok, TaskRun.t()} | {:error, :not_found}
  def fetch_active_for_task(task_id) when is_binary(task_id) do
    Sacrum.Repo.TaskRuns.fetch_active(conditions: [task_id: task_id])
  end

  @spec mark_waiting(binary() | TaskRun.t(), binary()) :: {:ok, TaskRun.t()} | {:error, term()}
  def mark_waiting(task_run_or_id, latest_step_execution_id) do
    with {:ok, %TaskRun{} = task_run} <- fetch_task_run(task_run_or_id) do
      task_run
      |> waiting_changeset(latest_step_execution_id)
      |> Repo.update()
    end
  end

  @spec mark_stopping(binary() | TaskRun.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  def mark_stopping(task_run_id) when is_binary(task_run_id) do
    case fetch_task_run(task_run_id) do
      {:ok, task_run} -> mark_stopping(task_run)
      {:error, reason} -> {:error, reason}
    end
  end

  def mark_stopping(%TaskRun{} = task_run) do
    cond do
      TaskRunStatus.stoppable?(task_run.status) ->
        task_run
        |> stopping_changeset()
        |> Repo.update()

      task_run.status == :stopping ->
        {:ok, task_run}

      true ->
        {:error, {:task_run_not_stoppable, task_run.status}}
    end
  end

  @spec mark_stopped(binary() | TaskRun.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  def mark_stopped(task_run_or_id) do
    with {:ok, %TaskRun{} = task_run} <- fetch_task_run(task_run_or_id) do
      task_run
      |> stopped_changeset()
      |> Repo.update()
    end
  end

  @spec mark_completed(binary() | TaskRun.t(), map()) :: {:ok, TaskRun.t()} | {:error, term()}
  def mark_completed(task_run_or_id, attrs \\ %{}) when is_map(attrs) do
    with {:ok, %TaskRun{} = task_run} <- fetch_task_run(task_run_or_id) do
      task_run
      |> completed_changeset(attrs)
      |> Repo.update()
    end
  end

  @spec mark_failed(binary() | TaskRun.t(), term(), map()) ::
          {:ok, TaskRun.t()} | {:error, term()}
  def mark_failed(task_run_or_id, reason, context \\ %{}) when is_map(context) do
    with {:ok, %TaskRun{} = task_run} <- fetch_task_run(task_run_or_id) do
      task_run
      |> failed_changeset(reason, context)
      |> Repo.update()
    end
  end

  @spec mark_failed_if_active(binary() | TaskRun.t(), term(), map()) ::
          {:ok, TaskRun.t()} | {:ok, :unchanged} | {:error, term()}
  def mark_failed_if_active(task_run_or_id, reason, context \\ %{}) when is_map(context) do
    with {:ok, %TaskRun{} = task_run} <- fetch_task_run(task_run_or_id) do
      if TaskRunStatus.stoppable?(task_run.status),
        do: mark_failed(task_run, reason, context),
        else: {:ok, :unchanged}
    end
  end

  @spec waiting_changeset(TaskRun.t(), binary()) :: Ecto.Changeset.t()
  def waiting_changeset(%TaskRun{} = task_run, latest_step_execution_id) do
    TaskRun.update_changeset(task_run, %{
      status: :waiting,
      latest_step_execution_id: latest_step_execution_id
    })
  end

  @spec stopping_changeset(TaskRun.t()) :: Ecto.Changeset.t()
  def stopping_changeset(%TaskRun{} = task_run) do
    TaskRun.update_changeset(task_run, %{status: :stopping, stop_requested_at: DateTime.utc_now()})
  end

  @spec stopped_changeset(TaskRun.t(), map()) :: Ecto.Changeset.t()
  def stopped_changeset(%TaskRun{} = task_run, attrs \\ %{}) when is_map(attrs) do
    attrs
    |> Map.merge(%{status: :stopped, ended_at: DateTime.utc_now()})
    |> then(&TaskRun.update_changeset(task_run, &1))
  end

  @spec completed_changeset(TaskRun.t(), map()) :: Ecto.Changeset.t()
  def completed_changeset(%TaskRun{} = task_run, attrs \\ %{}) when is_map(attrs) do
    attrs
    |> Map.merge(%{status: :completed, ended_at: DateTime.utc_now()})
    |> then(&TaskRun.update_changeset(task_run, &1))
  end

  @spec failed_changeset(TaskRun.t(), term(), map()) :: Ecto.Changeset.t()
  def failed_changeset(%TaskRun{} = task_run, reason, context \\ %{}) when is_map(context) do
    TaskRun.update_changeset(task_run, %{
      status: :failed,
      ended_at: DateTime.utc_now(),
      failure_kind: failure_kind(reason),
      failure_reason: failure_reason(reason),
      failure_context: stringify_context(context)
    })
  end

  @spec fetch_task_run(binary() | TaskRun.t()) ::
          {:ok, TaskRun.t()} | {:error, :task_run_not_found}
  def fetch_task_run(%TaskRun{} = task_run), do: {:ok, task_run}

  def fetch_task_run(task_run_id) when is_binary(task_run_id) do
    case Repo.get(TaskRun, task_run_id) do
      nil -> {:error, :task_run_not_found}
      task_run -> {:ok, task_run}
    end
  end

  defp failure_kind({kind, _reason}) when is_atom(kind), do: Atom.to_string(kind)
  defp failure_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp failure_kind(_reason), do: "orchestrator_failure"

  defp failure_reason(reason) when is_binary(reason), do: reason
  defp failure_reason(reason), do: inspect(reason)

  defp stringify_context(context) do
    Map.new(context, fn {key, value} -> {to_string(key), value} end)
  end

  defp create_child_run(%Task{} = child, %TaskRun{} = parent_task_run, trigger_id) do
    TaskRuns.insert(child.user_id, child.project_id, child.id, %{
      status: :queued,
      parent_task_run_id: parent_task_run.id,
      root_task_run_id: root_task_run_id(parent_task_run),
      triggered_by_step_execution_id: trigger_id
    })
  end

  defp reconcile_child_run(%TaskRun{} = task_run, %TaskRun{} = parent_task_run, trigger_id) do
    if task_run.parent_task_run_id == parent_task_run.id and
         task_run.root_task_run_id == root_task_run_id(parent_task_run) do
      reconcile_child_run_trigger(task_run, trigger_id)
    else
      reject_child_run_lineage(task_run)
    end
  end

  defp reconcile_child_run_trigger(
         %TaskRun{triggered_by_step_execution_id: nil} = task_run,
         trigger_id
       ) do
    stamp_trigger(task_run, trigger_id)
  end

  defp reconcile_child_run_trigger(
         %TaskRun{triggered_by_step_execution_id: trigger_id} = task_run,
         trigger_id
       ) do
    validate_dispatchable(task_run)
  end

  defp reconcile_child_run_trigger(%TaskRun{} = task_run, _trigger_id) do
    {:error, {:child_task_run_lineage_conflict, task_run.id}}
  end

  defp reject_child_run_lineage(
         %TaskRun{parent_task_run_id: nil, root_task_run_id: nil} = task_run
       ) do
    {:error, {:child_task_run_has_manual_root, task_run.id}}
  end

  defp reject_child_run_lineage(%TaskRun{} = task_run) do
    {:error, {:child_task_run_lineage_conflict, task_run.id}}
  end

  defp stamp_trigger(%TaskRun{} = task_run, trigger_id) do
    with {:ok, task_run} <-
           task_run
           |> TaskRun.lineage_changeset(%{triggered_by_step_execution_id: trigger_id})
           |> Repo.update() do
      validate_dispatchable(task_run)
    end
  end

  defp root_task_run_id(%TaskRun{root_task_run_id: nil, id: id}), do: id
  defp root_task_run_id(%TaskRun{root_task_run_id: root_task_run_id}), do: root_task_run_id
end
