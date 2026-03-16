defmodule Sacrum.Orchestrator.Scheduler do
  @moduledoc """
  Coordinates task scheduling and dependency unblocking.

  - `schedule_task/1` starts a TaskOrchestrator for a task
  - `notify_task_completed/2` unblocks dependent tasks and starts their orchestrators
  """

  use GenServer

  require Logger
  alias Sacrum.Orchestrator.{TaskOrchestrator, TaskRegistry}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.TaskDependencies

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec schedule_task(map()) :: :ok | {:error, term()}
  def schedule_task(task) do
    GenServer.call(__MODULE__, {:schedule_task, task})
  end

  @spec notify_task_completed(binary(), map()) :: :ok | {:error, term()}
  def notify_task_completed(task_id, result) do
    GenServer.call(__MODULE__, {:notify_task_completed, task_id, result})
  end

  @impl true
  def init(_opts) do
    Logger.info("[Scheduler] Initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:schedule_task, task}, _from, state) do
    result = validate_and_schedule(task)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:notify_task_completed, task_id, _result}, _from, state) do
    case notify_dependents(task_id) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        Logger.error(
          "[Scheduler] Error notifying dependents of task #{task_id}: #{inspect(reason)}"
        )

        {:reply, {:error, reason}, state}
    end
  end

  # ===== PRIVATE HELPERS =====

  defp validate_and_schedule(task) do
    Logger.info("[Scheduler] validate_and_schedule called with #{inspect(Map.keys(task))}")

    with {:ok, task_id} <- extract_task_id(task),
         {:ok, task_record} <- fetch_task(task_id),
         :ok <- validate_workflow(task_record),
         :ok <- validate_not_completed(task_record),
         :ok <- validate_no_active_fsm(task_id) do
      Logger.info(
        "[Scheduler] All validations passed for task_id=#{task_id}, starting orchestrator"
      )

      start_orchestrator(task_id, task_record.user_id)
    else
      {:error, reason} = err ->
        Logger.error("[Scheduler] validate_and_schedule failed: #{inspect(reason)}")
        err
    end
  end

  defp extract_task_id(task) do
    case Map.fetch(task, :id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :missing_task_id}
    end
  end

  defp validate_workflow(task) do
    if task.workflow_id, do: :ok, else: {:error, :no_workflow_assigned}
  end

  defp validate_not_completed(task) do
    if is_nil(task.completed_at), do: :ok, else: {:error, :task_already_completed}
  end

  defp validate_no_active_fsm(task_id) do
    if fsm_running?(task_id), do: {:error, :orchestrator_already_running}, else: :ok
  end

  defp notify_dependents(task_id) do
    with {:ok, task} <- fetch_task(task_id) do
      dependent_tasks = TaskDependencies.get_blocking(task)
      Enum.each(dependent_tasks, &try_start_orchestrator_for_task/1)
      :ok
    end
  end

  defp fetch_task(task_id) do
    case Repo.get(Task, task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, task}
    end
  end

  defp try_start_orchestrator_for_task(dependent_task) do
    cond do
      dependent_task.completed_at ->
        :skip

      !dependent_task.workflow_id ->
        :skip

      !all_blockers_complete?(dependent_task) ->
        :skip

      true ->
        start_orchestrator_if_not_running(dependent_task.id, dependent_task.user_id)
    end
  end

  defp all_blockers_complete?(task) do
    task
    |> TaskDependencies.get_direct_blockers()
    |> Enum.all?(&(not is_nil(&1.completed_at)))
  end

  defp start_orchestrator_if_not_running(task_id, user_id) do
    unless fsm_running?(task_id), do: start_orchestrator(task_id, user_id)
  end

  defp fsm_running?(task_id) do
    Registry.lookup(TaskRegistry, task_id) != []
  end

  defp start_orchestrator(task_id, user_id) do
    alias Sacrum.Orchestrator.TaskFSMSupervisor
    child_opts = [task_id: task_id, user_id: user_id]

    Logger.info("[Scheduler] Starting orchestrator: task=#{task_id} user=#{user_id}")

    case TaskFSMSupervisor.start_child({TaskOrchestrator, child_opts}) do
      {:ok, pid} ->
        Logger.info("[Scheduler] Started orchestrator for task #{task_id}, pid=#{inspect(pid)}")
        :ok

      {:error, {:already_started, pid}} ->
        Logger.info(
          "[Scheduler] Orchestrator already running for task #{task_id}, pid=#{inspect(pid)}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "[Scheduler] Failed to start orchestrator for task #{task_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
