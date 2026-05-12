defmodule Sacrum.Orchestrator.TaskRuns.Root do
  @moduledoc """
  Root TaskRun acquisition and dispatchability checks.
  """

  alias Sacrum.Accounts.TaskRuns
  alias Sacrum.Orchestrator.TaskRuns.RunStart
  alias Sacrum.Repo.Schemas.{Task, TaskRun}
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @spec get_or_create(Task.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  def get_or_create(%Task{} = task) do
    case TaskRuns.get_active_for_task(task.user_id, task.id) do
      {:ok, %TaskRun{} = task_run} -> validate_dispatchable(task_run)
      {:error, :not_found} -> create(task)
    end
  end

  @spec validate_dispatchable(TaskRun.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  def validate_dispatchable(%TaskRun{} = task_run) do
    if TaskRunStatus.stoppable?(task_run.status),
      do: {:ok, task_run},
      else: {:error, {:task_run_not_dispatchable, task_run.status}}
  end

  @spec create(Task.t()) :: {:ok, TaskRun.t()} | {:error, term()}
  defp create(%Task{} = task) do
    case TaskRuns.insert(task.user_id, task.project_id, task.id, %{status: :queued}) do
      {:ok, %TaskRun{} = task_run} = result ->
        RunStart.broadcast_step_position(task_run, task)
        result

      error ->
        error
    end
  end
end
