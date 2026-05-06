defmodule Sacrum.Orchestrator.TaskRuns.Lookup do
  @moduledoc """
  Fetch helpers for durable task orchestration runs.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.TaskRun
  alias Sacrum.Repo.TaskRuns, as: TaskRunsRepo

  @spec fetch_active_for_task(binary()) :: {:ok, TaskRun.t()} | {:error, :not_found}
  def fetch_active_for_task(task_id) when is_binary(task_id) do
    TaskRunsRepo.fetch_active(conditions: [task_id: task_id])
  end

  @spec fetch(binary() | TaskRun.t()) :: {:ok, TaskRun.t()} | {:error, :task_run_not_found}
  def fetch(%TaskRun{} = task_run), do: {:ok, task_run}

  def fetch(task_run_id) when is_binary(task_run_id) do
    case Repo.get(TaskRun, task_run_id) do
      nil -> {:error, :task_run_not_found}
      task_run -> {:ok, task_run}
    end
  end
end
