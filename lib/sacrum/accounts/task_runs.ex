defmodule Sacrum.Accounts.TaskRuns do
  @moduledoc """
  User-scoped task run operations.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.TaskRuns,
    preloads: [],
    default_order: [desc: :inserted_at]

  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution, TaskRun}
  alias Sacrum.Repo.TaskRuns, as: TaskRunsRepo

  @spec insert(String.t(), String.t(), String.t(), map()) ::
          {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, project_id, task_id, attrs \\ %{})
      when is_binary(user_id) and is_binary(project_id) and is_binary(task_id) and is_map(attrs) do
    result = TaskRunsRepo.insert(user_id, project_id, task_id, attrs)
    Broadcaster.broadcast_task_run(result, :task_run_created)
  end

  @spec update(TaskRun.t(), map()) :: {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def update(%TaskRun{} = task_run, attrs) do
    result = TaskRunsRepo.update(task_run, attrs)
    Broadcaster.broadcast_task_run(result, :task_run_updated)
  end

  @spec get_active_for_task(String.t(), String.t()) :: {:ok, TaskRun.t()} | {:error, :not_found}
  def get_active_for_task(user_id, task_id) when is_binary(user_id) and is_binary(task_id) do
    TaskRunsRepo.fetch_active(conditions: [user_id: user_id, task_id: task_id])
  end

  @spec list_for_trace(String.t(), String.t()) :: [TaskRun.t()]
  defdelegate list_for_trace(user_id, root_task_run_id), to: TaskRunsRepo

  @spec list_descendants_for_trace(String.t(), String.t()) :: [TaskRun.t()]
  defdelegate list_descendants_for_trace(user_id, root_task_run_id), to: TaskRunsRepo

  @spec list_step_executions(String.t(), String.t()) :: [StepExecution.t()]
  def list_step_executions(user_id, task_run_id)
      when is_binary(user_id) and is_binary(task_run_id) do
    StepExecutions.list_by(user_id, conditions: [task_run_id: task_run_id])
  end

  @spec list_step_executions_for_trace(String.t(), String.t()) :: [StepExecution.t()]
  defdelegate list_step_executions_for_trace(user_id, root_task_run_id), to: TaskRunsRepo

  @spec list_session_logs_for_trace(String.t(), String.t()) :: [SessionLog.t()]
  defdelegate list_session_logs_for_trace(user_id, root_task_run_id), to: TaskRunsRepo
end
