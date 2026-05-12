defmodule Sacrum.Orchestrator.Routing.WaitChildren do
  @moduledoc """
  Handles wait_children step transitions.

  On entry: schedules each direct child, persists a 'waiting' StepExecution
  with the child IDs in its handoff, releases the pool slot and exits.

  On child completion (via `Scheduler.notify_task_completed/2`):
  `should_wake_parent/1` returns `:wake` when every child is completed and
  none is parked in a waiting execution, `:no_wake` otherwise.
  """

  require Logger

  import Ecto.Query

  alias Sacrum.Orchestrator.{ExecutionPool, FSMData, Scheduler}
  alias Sacrum.Orchestrator.Routing.WaitChildren.ChildRuns
  alias Sacrum.Orchestrator.TaskRuns.{Lookup, StateTransitions}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.{StepExecution, Task, TaskRun, WorkflowStep}
  alias Sacrum.Repo.{TaskDependencies, TaskHierarchy}
  alias Sacrum.Tasks.Status

  @spec handle_wait_children_entry(FSMData.t()) ::
          {:stop_parent, FSMData.t()}
          | {:advance_parent, FSMData.t()}
          | {:error_parent, FSMData.t()}
  def handle_wait_children_entry(data) do
    task_id = data.task.id

    case TaskHierarchy.get_children(data.task) do
      [] ->
        Logger.info(
          "[TaskOrchestrator:#{task_id}] wait_children entry with no children, advancing through outgoing transition"
        )

        {:advance_parent, data}

      children ->
        enter_with_children(data, children)
    end
  end

  @spec enter_with_children(FSMData.t(), [Task.t()]) ::
          {:stop_parent, FSMData.t()} | {:error_parent, FSMData.t()}
  defp enter_with_children(data, children) do
    task_id = data.task.id

    with :ok <- ensure_children_have_workflows(children),
         child_ids = Enum.map(children, & &1.id),
         {:ok, %{child_runs: child_runs}} <- enter_waiting_state(data, child_ids, children),
         :ok <- schedule_all_children(child_runs) do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Entered wait_children, scheduled #{length(children)} children"
      )

      ExecutionPool.release_slot(data.slot_id)
      {:stop_parent, %{data | slot_id: nil}}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed in wait_children entry: #{inspect(reason)}"
        )

        ExecutionPool.release_slot(data.slot_id)
        {:error_parent, %{data | slot_id: nil}}
    end
  end

  @spec should_wake_parent(Task.t()) :: :wake | :no_wake | {:error, term()}
  def should_wake_parent(task) do
    with {:ok, execution} <- fetch_waiting_execution(task.id),
         child_ids = Map.get(execution.handoff || %{}, "child_ids", []),
         {:ok, children} <- fetch_children(child_ids) do
      if all_done_and_not_parked?(children), do: :wake, else: :no_wake
    else
      {:error, :no_waiting_execution} -> :no_wake
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_children_have_workflows([Task.t()]) :: :ok | {:error, :child_missing_workflow}
  defp ensure_children_have_workflows(children) do
    if Enum.all?(children, & &1.workflow_id),
      do: :ok,
      else: {:error, :child_missing_workflow}
  end

  @spec enter_waiting_state(FSMData.t(), [binary()], [Task.t()]) ::
          {:ok, map()} | {:error, term()}
  defp enter_waiting_state(data, child_ids, children) do
    step_name =
      case data.steps[data.task.current_step_id] do
        %{name: name} -> name
        _ -> Repo.get!(WorkflowStep, data.task.current_step_id).name
      end

    attrs = %{
      task_id: data.task.id,
      task_run_id: data.task_run_id,
      workflow_id: data.task.workflow_id,
      step_id: data.task.current_step_id,
      step_name: step_name,
      status: "waiting",
      handoff: %{"child_ids" => child_ids}
    }

    with {:ok, task_run} <- Lookup.fetch(data.task_run_id) do
      Repo.transaction(fn -> commit_waiting_state(data, attrs, task_run, children) end)
    end
  end

  @spec commit_waiting_state(FSMData.t(), map(), TaskRun.t(), [Task.t()]) :: map()
  defp commit_waiting_state(data, attrs, task_run, children) do
    with {:ok, execution} <- Repo.insert(waiting_step_execution_changeset(data, attrs)),
         {:ok, updated_task_run} <-
           task_run
           |> StateTransitions.waiting_changeset(execution.id)
           |> Repo.update(),
         {:ok, updated_task} <- Repo.update(Status.changeset(data.task)),
         {:ok, child_runs} <- get_or_create_child_runs(children, updated_task_run, execution.id) do
      Broadcaster.broadcast_task_run({:ok, updated_task_run}, :task_run_updated)

      %{
        execution: execution,
        task_run: updated_task_run,
        task: updated_task,
        child_runs: child_runs
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec waiting_step_execution_changeset(FSMData.t(), map()) :: Ecto.Changeset.t()
  defp waiting_step_execution_changeset(data, attrs) do
    StepExecution.create_changeset(
      %StepExecution{user_id: data.user_id, project_id: data.project_id},
      attrs
    )
  end

  @spec get_or_create_child_runs([Task.t()], TaskRun.t(), binary()) ::
          {:ok, [{Task.t(), TaskRun.t()}]} | {:error, term()}
  defp get_or_create_child_runs(children, parent_task_run, triggered_by_step_execution_id) do
    child_runs =
      Enum.reduce_while(children, {:ok, []}, fn child, {:ok, acc} ->
        case ChildRuns.get_or_create(
               child,
               parent_task_run,
               triggered_by_step_execution_id
             ) do
          {:ok, task_run} -> {:cont, {:ok, [{child, task_run} | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case child_runs do
      {:ok, child_runs} -> {:ok, Enum.reverse(child_runs)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec schedule_all_children([{Task.t(), TaskRun.t()}]) :: :ok | {:error, term()}
  defp schedule_all_children(child_runs) do
    blocked =
      child_runs
      |> Enum.map(fn {child, _} -> child.id end)
      |> TaskDependencies.incomplete_direct_blocker_task_ids()
      |> MapSet.new()

    child_runs
    |> Enum.reject(fn {child, _} -> MapSet.member?(blocked, child.id) end)
    |> Enum.reduce_while(:ok, fn {child, task_run}, _acc ->
      case start_child_orchestrator(child, task_run) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  @spec start_child_orchestrator(Task.t(), TaskRun.t()) :: :ok | {:error, term()}
  defp start_child_orchestrator(child, task_run) do
    case Registry.lookup(Sacrum.Orchestrator.TaskRegistry, child.id) do
      [_ | _] ->
        :ok

      [] ->
        case Scheduler.schedule_task_run(child.id, task_run.id) do
          :ok -> :ok
          {:error, :orchestrator_already_running} -> :ok
          {:error, reason} -> log_child_start_failure(child, reason)
        end
    end
  end

  @spec log_child_start_failure(Task.t(), term()) :: {:error, term()}
  defp log_child_start_failure(child, reason) do
    Logger.error(
      "[WaitChildren] Failed to start child orchestrator for task #{child.id}: #{inspect(reason)}"
    )

    {:error, reason}
  end

  @spec fetch_waiting_execution(binary()) ::
          {:ok, StepExecution.t()} | {:error, :no_waiting_execution}
  defp fetch_waiting_execution(task_id) do
    query =
      from(e in StepExecution,
        where: e.task_id == ^task_id and e.status == "waiting",
        order_by: [desc: e.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :no_waiting_execution}
      execution -> {:ok, execution}
    end
  end

  @spec fetch_children([binary()] | term()) ::
          {:ok, [Task.t()]} | {:error, :child_not_found | :invalid_child_ids}
  defp fetch_children([]), do: {:ok, []}

  defp fetch_children(child_ids) when is_list(child_ids) do
    children = Repo.all(from(t in Task, where: t.id in ^child_ids))

    if length(children) == length(child_ids),
      do: {:ok, children},
      else: {:error, :child_not_found}
  end

  defp fetch_children(_), do: {:error, :invalid_child_ids}

  @spec all_done_and_not_parked?([Task.t()]) :: boolean()
  defp all_done_and_not_parked?(children) do
    Enum.all?(children, fn task ->
      not is_nil(task.completed_at) and not has_waiting_execution?(task.id)
    end)
  end

  @spec has_waiting_execution?(binary()) :: boolean()
  defp has_waiting_execution?(task_id) do
    Repo.exists?(from(e in StepExecution, where: e.task_id == ^task_id and e.status == "waiting"))
  end
end
