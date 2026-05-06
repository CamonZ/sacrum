defmodule Sacrum.Orchestrator.Scheduler do
  @moduledoc """
  Coordinates task scheduling and dependency unblocking.

  - `schedule_task/1` starts a TaskOrchestrator for a task
  - `notify_task_completed/2` unblocks dependent tasks and starts their orchestrators
  """

  use GenServer

  require Logger

  alias Sacrum.Orchestrator.Routing.WaitChildren
  alias Sacrum.Orchestrator.{TaskOrchestrator, TaskRegistry}
  alias Sacrum.Orchestrator.TaskRuns.{Lookup, Root}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Task, TaskRun}
  alias Sacrum.Repo.{TaskDependencies, TaskHierarchy}

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec schedule_task(map()) :: :ok | {:error, term()}
  def schedule_task(task) do
    GenServer.call(__MODULE__, {:schedule_task, task})
  end

  @spec schedule_task_run(binary(), binary()) :: :ok | {:error, term()}
  def schedule_task_run(task_id, task_run_id)
      when is_binary(task_id) and is_binary(task_run_id) do
    GenServer.call(__MODULE__, {:schedule_task_run, task_id, task_run_id})
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
  def handle_call({:schedule_task_run, task_id, task_run_id}, _from, state) do
    result = validate_and_schedule_existing_run(task_id, task_run_id)
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

  @spec validate_and_schedule(map()) :: :ok | {:error, term()}
  defp validate_and_schedule(task) do
    Logger.info("[Scheduler] validate_and_schedule called with #{inspect(Map.keys(task))}")

    with {:ok, task_id} <- extract_task_id(task),
         {:ok, task_record} <- fetch_task(task_id),
         :ok <- validate_workflow(task_record),
         :ok <- validate_not_completed(task_record),
         :ok <- validate_no_active_fsm(task_id),
         {:ok, task_run} <- Root.get_or_create(task_record) do
      Logger.info(
        "[Scheduler] All validations passed for task_id=#{task_id}, task_run_id=#{task_run.id}, starting orchestrator"
      )

      start_orchestrator(task_id, task_record.user_id, task_run.id)
    else
      {:error, reason} = err ->
        Logger.error("[Scheduler] validate_and_schedule failed: #{inspect(reason)}")
        err
    end
  end

  @spec validate_and_schedule_existing_run(binary(), binary()) :: :ok | {:error, term()}
  defp validate_and_schedule_existing_run(task_id, task_run_id) do
    with {:ok, task_record} <- fetch_task(task_id),
         :ok <- validate_workflow(task_record),
         :ok <- validate_not_completed(task_record),
         :ok <- validate_no_active_fsm(task_id),
         {:ok, task_run} <- Lookup.fetch(task_run_id),
         :ok <- validate_task_run_matches(task_run, task_record),
         {:ok, task_run} <- Root.validate_dispatchable(task_run) do
      Logger.info(
        "[Scheduler] Starting existing TaskRun task_id=#{task_id}, task_run_id=#{task_run.id}"
      )

      start_orchestrator(task_id, task_record.user_id, task_run.id)
    else
      {:error, reason} = err ->
        Logger.error("[Scheduler] validate_and_schedule_existing_run failed: #{inspect(reason)}")
        err
    end
  end

  @spec extract_task_id(map()) :: {:ok, binary()} | {:error, :missing_task_id}
  defp extract_task_id(task) do
    case Map.fetch(task, :id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :missing_task_id}
    end
  end

  @spec validate_workflow(Task.t()) :: :ok | {:error, :no_workflow_assigned}
  defp validate_workflow(task) do
    if task.workflow_id, do: :ok, else: {:error, :no_workflow_assigned}
  end

  @spec validate_not_completed(Task.t()) :: :ok | {:error, :task_already_completed}
  defp validate_not_completed(task) do
    if is_nil(task.completed_at), do: :ok, else: {:error, :task_already_completed}
  end

  @spec validate_no_active_fsm(binary()) :: :ok | {:error, :orchestrator_already_running}
  defp validate_no_active_fsm(task_id) do
    if fsm_running?(task_id), do: {:error, :orchestrator_already_running}, else: :ok
  end

  @spec validate_task_run_matches(TaskRun.t(), Task.t()) :: :ok | {:error, term()}
  defp validate_task_run_matches(task_run, task) do
    cond do
      task_run.user_id != task.user_id ->
        {:error, :task_run_user_mismatch}

      task_run.project_id != task.project_id ->
        {:error, :task_run_project_mismatch}

      task_run.task_id != task.id ->
        {:error, :task_run_task_mismatch}

      true ->
        :ok
    end
  end

  @spec notify_dependents(binary()) :: :ok | {:error, term()}
  defp notify_dependents(task_id) do
    with {:ok, task} <- fetch_task(task_id) do
      task
      |> TaskDependencies.get_blocking()
      |> Enum.each(&try_start_orchestrator_for_task/1)

      try_wake_parent(task)
      :ok
    end
  end

  @spec try_wake_parent(Task.t()) :: :ok | {:error, term()}
  defp try_wake_parent(task) do
    case TaskHierarchy.get_parent(task) do
      {:ok, parent} -> wake_parent_if_ready(parent)
      {:error, :not_found} -> :ok
    end
  end

  @spec wake_parent_if_ready(Task.t()) :: :ok | {:error, term()}
  defp wake_parent_if_ready(parent) do
    case WaitChildren.should_wake_parent(parent) do
      :wake ->
        Logger.info("[Scheduler] Parent task #{parent.id} all children done, waking")
        start_orchestrator_if_not_running(parent)

      :no_wake ->
        :ok

      {:error, reason} ->
        Logger.error("[Scheduler] Error checking parent wake status: #{inspect(reason)}")
        :ok
    end
  end

  @spec fetch_task(binary()) :: {:ok, Task.t()} | {:error, :task_not_found}
  defp fetch_task(task_id) do
    case Repo.get(Task, task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, task}
    end
  end

  @spec try_start_orchestrator_for_task(Task.t()) :: :ok | :skip | {:error, term()}
  defp try_start_orchestrator_for_task(dependent_task) do
    cond do
      dependent_task.completed_at ->
        :skip

      !dependent_task.workflow_id ->
        :skip

      !all_blockers_complete?(dependent_task) ->
        :skip

      true ->
        start_orchestrator_if_not_running(dependent_task)
    end
  end

  @spec all_blockers_complete?(Task.t()) :: boolean()
  defp all_blockers_complete?(task) do
    task
    |> TaskDependencies.get_direct_blockers()
    |> Enum.all?(&(not is_nil(&1.completed_at)))
  end

  @spec start_orchestrator_if_not_running(Task.t()) :: :ok | {:error, term()}
  defp start_orchestrator_if_not_running(task) do
    if fsm_running?(task.id) do
      :ok
    else
      with {:ok, task_run} <- Root.get_or_create(task) do
        start_orchestrator(task.id, task.user_id, task_run.id)
      end
    end
  end

  @spec fsm_running?(binary()) :: boolean()
  defp fsm_running?(task_id) do
    Registry.lookup(TaskRegistry, task_id) != []
  end

  @spec start_orchestrator(binary(), binary(), binary()) :: :ok | {:error, term()}
  defp start_orchestrator(task_id, user_id, task_run_id) do
    alias Sacrum.Orchestrator.TaskFSMSupervisor
    child_opts = [task_id: task_id, user_id: user_id, task_run_id: task_run_id]

    Logger.info(
      "[Scheduler] Starting orchestrator: task=#{task_id} user=#{user_id} task_run=#{task_run_id}"
    )

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
