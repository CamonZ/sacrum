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

  @spec list_for_trace(String.t(), String.t()) :: [TaskRun.t()]
  def list_for_trace(user_id, root_task_run_id)
      when is_binary(user_id) and is_binary(root_task_run_id) do
    user_id
    |> trace_scope_query(root_task_run_id)
    |> order_by_root_first(root_task_run_id)
    |> order_by([tr], asc: tr.inserted_at, asc: tr.id)
    |> Repo.all()
  end

  @spec list_descendants_for_trace(String.t(), String.t()) :: [TaskRun.t()]
  def list_descendants_for_trace(user_id, root_task_run_id)
      when is_binary(user_id) and is_binary(root_task_run_id) do
    user_id
    |> trace_scope_query(root_task_run_id)
    |> where([tr], tr.id != ^root_task_run_id)
    |> order_by([tr], asc: tr.inserted_at, asc: tr.id)
    |> Repo.all()
  end

  @spec list_step_executions_for_trace(String.t(), String.t()) :: [StepExecution.t()]
  def list_step_executions_for_trace(user_id, root_task_run_id)
      when is_binary(user_id) and is_binary(root_task_run_id) do
    user_id
    |> trace_scope_query(root_task_run_id)
    |> join(:inner, [tr], e in StepExecution,
      on: e.task_run_id == tr.id and e.user_id == ^user_id and e.project_id == tr.project_id
    )
    |> order_by_root_first(root_task_run_id)
    |> order_by([tr, e], asc: tr.inserted_at, asc: tr.id, asc: e.inserted_at, asc: e.id)
    |> select([_tr, e], e)
    |> Repo.all()
  end

  @spec list_session_logs_for_trace(String.t(), String.t()) :: [SessionLog.t()]
  def list_session_logs_for_trace(user_id, root_task_run_id)
      when is_binary(user_id) and is_binary(root_task_run_id) do
    user_id
    |> trace_scope_query(root_task_run_id)
    |> join(:inner, [tr], e in StepExecution,
      on: e.task_run_id == tr.id and e.user_id == ^user_id and e.project_id == tr.project_id
    )
    |> join(:inner, [_tr, e], log in SessionLog,
      on:
        log.step_execution_id == e.id and log.user_id == ^user_id and
          log.project_id == e.project_id
    )
    |> order_by_root_first(root_task_run_id)
    |> order_by(
      [tr, e, log],
      asc: tr.inserted_at,
      asc: tr.id,
      asc: e.inserted_at,
      asc: e.id,
      asc: log.inserted_at,
      asc: log.id
    )
    |> select([_tr, _e, log], log)
    |> Repo.all()
  end

  defp trace_scope_query(user_id, root_task_run_id) do
    TaskRun
    |> apply_conditions(user_id: user_id)
    |> where(
      [tr],
      tr.id == ^root_task_run_id or tr.root_task_run_id == ^root_task_run_id
    )
  end

  defp order_by_root_first(query, root_task_run_id) do
    order_by(
      query,
      [tr],
      asc:
        fragment(
          "CASE WHEN ? = ? THEN 0 ELSE 1 END",
          tr.id,
          type(^root_task_run_id, :binary_id)
        )
    )
  end
end
