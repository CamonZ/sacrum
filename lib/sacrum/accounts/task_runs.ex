defmodule Sacrum.Accounts.TaskRuns do
  @moduledoc """
  User-scoped task run operations.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.TaskRuns,
    preloads: [],
    default_order: [desc: :inserted_at]

  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution, TaskRun}
  alias Sacrum.Repo.TaskRuns, as: TaskRunsRepo

  @spec insert(String.t(), String.t(), String.t(), map()) ::
          {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, project_id, task_id, attrs \\ %{})
      when is_binary(user_id) and is_binary(project_id) and is_binary(task_id) and is_map(attrs) do
    TaskRunsRepo.insert(user_id, project_id, task_id, attrs)
  end

  @spec update(TaskRun.t(), map()) :: {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def update(%TaskRun{} = task_run, attrs) do
    TaskRunsRepo.update(task_run, attrs)
  end

  @spec get_active_for_task(String.t(), String.t()) :: {:ok, TaskRun.t()} | {:error, :not_found}
  def get_active_for_task(user_id, task_id) when is_binary(user_id) and is_binary(task_id) do
    TaskRunsRepo.fetch_active(conditions: [user_id: user_id, task_id: task_id])
  end

  @spec list_active_for_tasks(String.t(), [String.t()]) :: [TaskRun.t()]
  defdelegate list_active_for_tasks(user_id, task_ids), to: TaskRunsRepo

  @spec list_step_executions(String.t(), String.t()) :: [StepExecution.t()]
  def list_step_executions(user_id, task_run_id)
      when is_binary(user_id) and is_binary(task_run_id) do
    TaskRunsRepo.list_step_executions_for_run(user_id, task_run_id)
  end

  @spec list_step_executions_for_run(String.t(), String.t()) :: [StepExecution.t()]
  defdelegate list_step_executions_for_run(user_id, task_run_id), to: TaskRunsRepo

  @spec list_session_logs_for_run(String.t(), String.t()) :: [SessionLog.t()]
  defdelegate list_session_logs_for_run(user_id, task_run_id), to: TaskRunsRepo
end
