defmodule Sacrum.Repo.TaskRuns do
  @moduledoc """
  Database operations for durable task orchestration runs.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.TaskRun

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution, TaskRun}
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @spec insert(String.t(), String.t(), String.t(), map()) ::
          {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, project_id, task_id, attrs)
      when is_binary(user_id) and is_binary(project_id) and is_binary(task_id) and is_map(attrs) do
    %TaskRun{user_id: user_id, project_id: project_id, task_id: task_id}
    |> TaskRun.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec update(TaskRun.t(), map()) :: {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def update(%TaskRun{} = task_run, attrs) do
    task_run
    |> TaskRun.update_changeset(attrs)
    |> Repo.update()
  end

  @spec fetch_active(keyword()) :: {:ok, TaskRun.t()} | {:error, :not_found}
  def fetch_active(opts) when is_list(opts) do
    conditions = Keyword.fetch!(opts, :conditions)

    query =
      TaskRun
      |> apply_conditions(conditions)
      |> where([tr], tr.status in ^TaskRunStatus.active_statuses())
      |> order_by([tr], desc: tr.inserted_at)
      |> limit(1)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      task_run -> {:ok, task_run}
    end
  end

  @spec list_active_for_tasks(String.t(), [String.t()]) :: [TaskRun.t()]
  def list_active_for_tasks(_user_id, []), do: []

  def list_active_for_tasks(user_id, task_ids)
      when is_binary(user_id) and is_list(task_ids) do
    task_ids = Enum.uniq(task_ids)

    TaskRun
    |> where([tr], tr.user_id == ^user_id)
    |> where([tr], tr.task_id in ^task_ids)
    |> where([tr], tr.status in ^TaskRunStatus.active_statuses())
    |> order_by([tr], desc: tr.inserted_at)
    |> Repo.all()
    |> Repo.preload(:latest_step_execution)
  end

  @spec list_active_for_project(String.t(), String.t()) :: [TaskRun.t()]
  def list_active_for_project(user_id, project_id)
      when is_binary(user_id) and is_binary(project_id) do
    TaskRun
    |> where([tr], tr.user_id == ^user_id)
    |> where([tr], tr.project_id == ^project_id)
    |> where([tr], tr.status in ^TaskRunStatus.active_statuses())
    |> order_by([tr], desc: tr.inserted_at)
    |> Repo.all()
    |> Repo.preload(:latest_step_execution)
  end

  @spec list_step_executions_for_run(String.t(), String.t()) :: [StepExecution.t()]
  def list_step_executions_for_run(user_id, task_run_id)
      when is_binary(user_id) and is_binary(task_run_id) do
    StepExecution
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.task_run_id == ^task_run_id)
    |> order_by([e], asc: e.inserted_at, asc: e.id)
    |> Repo.all()
  end

  @spec list_session_logs_for_run(String.t(), String.t()) :: [SessionLog.t()]
  def list_session_logs_for_run(user_id, task_run_id)
      when is_binary(user_id) and is_binary(task_run_id) do
    StepExecution
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.task_run_id == ^task_run_id)
    |> join(:inner, [e], log in SessionLog,
      on:
        log.step_execution_id == e.id and log.user_id == ^user_id and
          log.project_id == e.project_id
    )
    |> order_by(
      [e, log],
      asc: e.inserted_at,
      asc: e.id,
      asc: log.inserted_at,
      asc: log.id
    )
    |> select([_e, log], log)
    |> Repo.all()
  end
end
