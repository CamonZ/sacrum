defmodule Sacrum.Repo.TaskRuns do
  @moduledoc """
  Database operations for durable task orchestration runs.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.TaskRun

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.TaskRun
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

  @spec list_for_trace(keyword()) :: [TaskRun.t()]
  def list_for_trace(opts) when is_list(opts) do
    conditions = Keyword.fetch!(opts, :conditions)
    root_task_run_id = Keyword.fetch!(opts, :root_task_run_id)

    TaskRun
    |> apply_conditions(conditions)
    |> where(
      [tr],
      tr.id == ^root_task_run_id or tr.root_task_run_id == ^root_task_run_id
    )
    |> order_by([tr], asc: tr.inserted_at)
    |> Repo.all()
  end
end
