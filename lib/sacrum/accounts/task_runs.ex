defmodule Sacrum.Accounts.TaskRuns do
  @moduledoc """
  User-scoped task run operations.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.TaskRuns,
    preloads: [],
    default_order: [desc: :inserted_at]

  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Schemas.{SessionLog, StepExecution, TaskRun}
  alias Sacrum.Repo.TaskRuns, as: TaskRunsRepo

  @default_history_page_size 50
  @max_history_page_size 200

  @type history_page :: %{
          entries: [TaskRunsRepo.history_entry()],
          has_more: boolean(),
          hidden_completed_count: non_neg_integer()
        }

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

  @spec get_concurrency_scope(TaskRun.t()) ::
          {:ok, TaskRunsRepo.concurrency_scope()} | {:error, :not_found}
  defdelegate get_concurrency_scope(task_run), to: TaskRunsRepo

  @spec get_active_for_task(String.t(), String.t()) :: {:ok, TaskRun.t()} | {:error, :not_found}
  def get_active_for_task(user_id, task_id) when is_binary(user_id) and is_binary(task_id) do
    TaskRunsRepo.fetch_active(conditions: [user_id: user_id, task_id: task_id])
  end

  @spec get_in_scope(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, TaskRun.t()} | {:error, :not_found}
  defdelegate get_in_scope(user_id, project_id, task_id, task_run_id),
    to: TaskRunsRepo,
    as: :fetch_in_scope

  @spec list_active_for_tasks(String.t(), [String.t()]) :: [TaskRun.t()]
  defdelegate list_active_for_tasks(user_id, task_ids), to: TaskRunsRepo

  @spec list_active_for_project(String.t(), String.t()) :: [TaskRun.t()]
  defdelegate list_active_for_project(user_id, project_id), to: TaskRunsRepo

  @spec list_step_executions(String.t(), String.t()) :: [StepExecution.t()]
  def list_step_executions(user_id, task_run_id)
      when is_binary(user_id) and is_binary(task_run_id) do
    TaskRunsRepo.list_step_executions_for_run(user_id, task_run_id)
  end

  @spec list_step_executions_for_run(String.t(), String.t()) :: [StepExecution.t()]
  defdelegate list_step_executions_for_run(user_id, task_run_id), to: TaskRunsRepo

  @spec list_step_executions_for_run(String.t(), String.t(), String.t(), String.t()) :: [
          StepExecution.t()
        ]
  defdelegate list_step_executions_for_run(user_id, project_id, task_id, task_run_id),
    to: TaskRunsRepo

  @spec list_session_logs_for_run(String.t(), String.t()) :: [SessionLog.t()]
  defdelegate list_session_logs_for_run(user_id, task_run_id), to: TaskRunsRepo

  @spec max_history_page_size() :: pos_integer()
  def max_history_page_size, do: @max_history_page_size

  @doc """
  Page through a project's run history, most recently updated first.

  Options:

    * `:cursor` - the `updated_at`/`id` of the last entry the caller already
      holds; results start strictly after it.
    * `:limit` - page size, 1 to #{@max_history_page_size}; defaults to
      #{@default_history_page_size}.
    * `:include_completed` - include runs of completed tasks and runs that
      finished `completed` or `stopped`; defaults to `false`.
    * `:search` - matches a run or task id prefix, or a task title substring,
      case-insensitively. Blank searches match everything.

  `hidden_completed_count` counts the matching finished runs of open tasks that the completed
  filter hides; it is zero when completed history is included.
  """
  @spec list_history_for_project(String.t(), String.t(), keyword()) ::
          {:ok, history_page()} | {:error, :not_found | :invalid_limit}
  def list_history_for_project(user_id, project_id, opts \\ [])
      when is_binary(user_id) and is_binary(project_id) and is_list(opts) do
    limit = Keyword.get(opts, :limit) || @default_history_page_size
    include_completed = Keyword.get(opts, :include_completed, false)
    search = normalize_search(Keyword.get(opts, :search))

    with :ok <- validate_history_limit(limit),
         {:ok, _project} <- Projects.get_by(user_id, conditions: [id: project_id]) do
      rows =
        TaskRunsRepo.list_history_for_project(
          user_id,
          project_id,
          Keyword.get(opts, :cursor),
          limit + 1,
          include_completed,
          search
        )

      {entries, rest} = Enum.split(rows, limit)

      hidden_completed_count =
        if include_completed,
          do: 0,
          else: TaskRunsRepo.count_hidden_completed_history(user_id, project_id, search)

      {:ok,
       %{entries: entries, has_more: rest != [], hidden_completed_count: hidden_completed_count}}
    end
  end

  defp normalize_search(search) when is_binary(search),
    do: search |> String.trim() |> String.downcase()

  defp normalize_search(_search), do: nil

  defp validate_history_limit(limit)
       when is_integer(limit) and limit in 1..@max_history_page_size,
       do: :ok

  defp validate_history_limit(_limit), do: {:error, :invalid_limit}
end
