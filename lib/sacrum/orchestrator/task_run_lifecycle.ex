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
    update_task_run(task_run_or_id, %{
      status: :waiting,
      latest_step_execution_id: latest_step_execution_id
    })
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
        update_task_run(task_run, %{status: :stopping, stop_requested_at: DateTime.utc_now()})

      task_run.status == :stopping ->
        {:ok, task_run}

      true ->
        {:error, {:task_run_not_stoppable, task_run.status}}
    end
  end

  @spec mark_stopped(binary() | TaskRun.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  def mark_stopped(task_run_or_id) do
    update_task_run(task_run_or_id, %{status: :stopped, ended_at: DateTime.utc_now()})
  end

  @spec mark_completed(binary() | TaskRun.t(), map()) :: {:ok, TaskRun.t()} | {:error, term()}
  def mark_completed(task_run_or_id, attrs \\ %{}) when is_map(attrs) do
    attrs
    |> Map.merge(%{status: :completed, ended_at: DateTime.utc_now()})
    |> then(&update_task_run(task_run_or_id, &1))
  end

  @spec mark_failed(binary() | TaskRun.t(), term(), map()) ::
          {:ok, TaskRun.t()} | {:error, term()}
  def mark_failed(task_run_or_id, reason, context \\ %{}) when is_map(context) do
    update_task_run(task_run_or_id, %{
      status: :failed,
      ended_at: DateTime.utc_now(),
      failure_kind: failure_kind(reason),
      failure_reason: failure_reason(reason),
      failure_context: stringify_context(context)
    })
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

  defp update_task_run(task_run_or_id, attrs) do
    with {:ok, %TaskRun{} = task_run} <- fetch_task_run(task_run_or_id) do
      TaskRuns.update(task_run, attrs)
    end
  end

  defp fetch_task_run(%TaskRun{} = task_run), do: {:ok, task_run}

  defp fetch_task_run(task_run_id) when is_binary(task_run_id) do
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
end
