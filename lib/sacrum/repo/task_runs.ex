defmodule Sacrum.Repo.TaskRuns do
  @moduledoc """
  Database operations for durable task orchestration runs.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.TaskRun

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution, Task, TaskRun, Workflow}
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @type concurrency_scope :: %{id: String.t(), max_concurrency: pos_integer() | nil}

  @typedoc "The `updated_at`/`id` of the last history entry a caller already holds."
  @type history_cursor :: %{updated_at: DateTime.t(), id: String.t()}

  @typedoc "Task fields the run-history sidebar needs to label and group a run."
  @type history_task :: %{
          id: String.t(),
          title: String.t(),
          level: String.t(),
          parent_id: String.t() | nil,
          workflow_id: String.t(),
          workflow_name: String.t(),
          completed_at: DateTime.t() | nil
        }

  @type history_entry :: %{task_run: TaskRun.t(), task: history_task()}

  # Finished runs that count as completed history; failed runs stay visible.
  @completed_history_statuses [:completed, :stopped]

  @spec insert(String.t(), String.t(), String.t(), map()) ::
          {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, project_id, task_id, attrs)
      when is_binary(user_id) and is_binary(project_id) and is_binary(task_id) and is_map(attrs) do
    if Repo.in_transaction?() do
      insert_locked(user_id, project_id, task_id, attrs)
    else
      insert_with_task_lock(user_id, project_id, task_id, attrs)
    end
  end

  defp insert_with_task_lock(user_id, project_id, task_id, attrs) do
    Repo.transaction(fn ->
      case Repo.one(from t in Task, where: t.id == ^task_id, lock: "FOR UPDATE") do
        nil -> Repo.rollback(:task_not_found)
        _task -> insert_locked!(user_id, project_id, task_id, attrs)
      end
    end)
  end

  @doc "Inserts a task run when the caller already holds the task lock."
  @spec insert_locked(String.t(), String.t(), String.t(), map()) ::
          {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def insert_locked(user_id, project_id, task_id, attrs)
      when is_binary(user_id) and is_binary(project_id) and is_binary(task_id) and is_map(attrs) do
    case insert_locked_result(user_id, project_id, task_id, attrs) do
      {:ok, task_run} -> {:ok, task_run}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp insert_locked!(user_id, project_id, task_id, attrs) do
    case insert_locked_result(user_id, project_id, task_id, attrs) do
      {:ok, task_run} -> task_run
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp insert_locked_result(user_id, project_id, task_id, attrs) do
    changeset =
      TaskRun.create_changeset(
        %TaskRun{user_id: user_id, project_id: project_id, task_id: task_id},
        attrs
      )

    Repo.insert(changeset)
  end

  @spec update(TaskRun.t(), map()) :: {:ok, TaskRun.t()} | {:error, Ecto.Changeset.t()}
  def update(%TaskRun{} = task_run, attrs) do
    task_run
    |> TaskRun.update_changeset(attrs)
    |> Repo.update()
  end

  @spec get_concurrency_scope(TaskRun.t()) ::
          {:ok, concurrency_scope()} | {:error, :not_found}
  def get_concurrency_scope(%TaskRun{root_task_run_id: nil, id: id, max_concurrency: limit}) do
    {:ok, %{id: id, max_concurrency: limit}}
  end

  def get_concurrency_scope(%TaskRun{root_task_run_id: root_task_run_id}) do
    case Repo.get(TaskRun, root_task_run_id) do
      %TaskRun{id: id, max_concurrency: limit} ->
        {:ok, %{id: id, max_concurrency: limit}}

      nil ->
        {:error, :not_found}
    end
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

  @doc "Locks owned runs and runs whose lineage references them before task deletion."
  @spec lock_for_task_deletion([String.t()]) :: [TaskRun.t()]
  def lock_for_task_deletion(task_ids) do
    owned_runs =
      Repo.all(
        from(tr in TaskRun,
          where: tr.task_id in ^task_ids,
          order_by: tr.id,
          lock: "FOR UPDATE"
        )
      )

    owned_ids = Enum.map(owned_runs, & &1.id)

    # Read links only after locking their targets, so new linked runs cannot
    # commit between the active-run check and lineage nullification.
    linked_runs =
      Repo.all(
        from(tr in TaskRun,
          where:
            tr.id not in ^owned_ids and
              (tr.parent_task_run_id in ^owned_ids or tr.root_task_run_id in ^owned_ids),
          order_by: tr.id,
          lock: "FOR UPDATE"
        )
      )

    owned_runs ++ linked_runs
  end

  @spec fetch_in_scope(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, TaskRun.t()} | {:error, :not_found}
  def fetch_in_scope(user_id, project_id, task_id, task_run_id)
      when is_binary(user_id) and is_binary(project_id) and is_binary(task_id) and
             is_binary(task_run_id) do
    query =
      from(tr in TaskRun,
        where:
          tr.id == ^task_run_id and tr.user_id == ^user_id and tr.project_id == ^project_id and
            tr.task_id == ^task_id,
        limit: 1
      )

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

  @spec list_step_executions_for_run(String.t(), String.t(), String.t(), String.t()) :: [
          StepExecution.t()
        ]
  def list_step_executions_for_run(user_id, project_id, task_id, task_run_id)
      when is_binary(user_id) and is_binary(project_id) and is_binary(task_id) and
             is_binary(task_run_id) do
    StepExecution
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.project_id == ^project_id)
    |> where([e], e.task_id == ^task_id)
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

  @doc """
  Lists up to `limit` run-history entries for a project, most recently
  updated first (`updated_at`, then `id`, descending), strictly after `cursor`
  when one is given.

  Runs of archived tasks are not history. Without `include_completed`, runs of completed tasks and runs that
  finished `completed` or `stopped` are skipped. `search` is a trimmed,
  lowercased query matching a run or task id prefix or a task title substring.
  """
  @spec list_history_for_project(
          String.t(),
          String.t(),
          history_cursor() | nil,
          pos_integer(),
          boolean(),
          String.t() | nil
        ) :: [history_entry()]
  def list_history_for_project(user_id, project_id, cursor, limit, include_completed, search)
      when is_binary(user_id) and is_binary(project_id) and is_integer(limit) and limit > 0 and
             is_boolean(include_completed) do
    user_id
    |> history_query(project_id, search)
    |> history_completion(include_completed)
    |> history_after(cursor)
    |> order_by([tr], desc: tr.updated_at, desc: tr.id)
    |> limit(^limit)
    |> select([tr, t, w], %{
      task_run: tr,
      task: %{
        id: t.id,
        title: t.title,
        level: t.level,
        parent_id: t.parent_id,
        workflow_id: t.workflow_id,
        workflow_name: w.name,
        completed_at: t.completed_at
      }
    })
    |> Repo.all()
  end

  @doc """
  Counts the history entries matching `search` that only the completed filter
  hides: finished runs of tasks that are not completed. Runs of completed tasks
  are not counted, matching what completed history adds for open tasks.
  """
  @spec count_hidden_completed_history(String.t(), String.t(), String.t() | nil) ::
          non_neg_integer()
  def count_hidden_completed_history(user_id, project_id, search)
      when is_binary(user_id) and is_binary(project_id) do
    user_id
    |> history_query(project_id, search)
    |> where([tr, t], is_nil(t.completed_at) and tr.status in ^@completed_history_statuses)
    |> select([tr], count(tr.id))
    |> Repo.one()
  end

  defp history_query(user_id, project_id, search) do
    query =
      from(tr in TaskRun,
        join: t in Task,
        on: t.id == tr.task_id and t.user_id == tr.user_id and t.project_id == tr.project_id,
        join: w in Workflow,
        on: w.id == t.workflow_id,
        where: tr.user_id == ^user_id and tr.project_id == ^project_id and t.archived == false
      )

    history_search(query, search)
  end

  defp history_completion(query, true), do: query

  defp history_completion(query, false) do
    where(
      query,
      [tr, t],
      is_nil(t.completed_at) and tr.status not in ^@completed_history_statuses
    )
  end

  defp history_after(query, nil), do: query

  defp history_after(query, %{updated_at: updated_at, id: id}) do
    where(
      query,
      [tr],
      tr.updated_at < ^updated_at or
        (tr.updated_at == ^updated_at and tr.id < type(^id, :binary_id))
    )
  end

  defp history_search(query, search) when search in [nil, ""], do: query

  defp history_search(query, search) when is_binary(search) do
    escaped = escape_like(search)
    prefix = escaped <> "%"
    substring = "%" <> escaped <> "%"

    where(
      query,
      [tr, t],
      fragment("?::text LIKE ?", tr.id, ^prefix) or fragment("?::text LIKE ?", t.id, ^prefix) or
        ilike(t.title, ^substring)
    )
  end

  defp escape_like(value), do: String.replace(value, ["\\", "%", "_"], &("\\" <> &1))
end
