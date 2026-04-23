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

  alias Sacrum.Orchestrator.{ExecutionPool, FSMData, TaskFSMSupervisor, TaskOrchestrator}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task, WorkflowStep}
  alias Sacrum.Repo.TaskHierarchy

  @spec handle_wait_children_entry(FSMData.t()) ::
          {:stop_parent, FSMData.t()} | {:error_parent, FSMData.t()}
  def handle_wait_children_entry(data) do
    task_id = data.task.id

    with {:ok, children} <- get_children(data.task),
         :ok <- ensure_children_have_workflows(children),
         child_ids = Enum.map(children, & &1.id),
         {:ok, _execution} <- create_waiting_execution(data, child_ids),
         :ok <- schedule_all_children(children, data.user_id) do
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

  defp get_children(task) do
    case TaskHierarchy.get_children(task) do
      [] -> {:error, :no_children}
      children -> {:ok, children}
    end
  end

  defp ensure_children_have_workflows(children) do
    if Enum.all?(children, & &1.workflow_id),
      do: :ok,
      else: {:error, :child_missing_workflow}
  end

  defp create_waiting_execution(data, child_ids) do
    step_name =
      case data.steps[data.task.current_step_id] do
        %{name: name} -> name
        _ -> Repo.get!(WorkflowStep, data.task.current_step_id).name
      end

    attrs = %{
      task_id: data.task.id,
      workflow_id: data.task.workflow_id,
      step_id: data.task.current_step_id,
      step_name: step_name,
      status: "waiting",
      handoff: %{"child_ids" => child_ids}
    }

    %StepExecution{user_id: data.user_id, project_id: data.project_id}
    |> StepExecution.create_changeset(attrs)
    |> Repo.insert()
  end

  defp schedule_all_children(children, user_id) do
    Enum.reduce_while(children, :ok, fn child, _acc ->
      case start_child_orchestrator(child, user_id) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp start_child_orchestrator(child, user_id) do
    case Registry.lookup(Sacrum.Orchestrator.TaskRegistry, child.id) do
      [_ | _] ->
        :ok

      [] ->
        case TaskFSMSupervisor.start_child(
               {TaskOrchestrator, task_id: child.id, user_id: user_id}
             ) do
          {:ok, _pid} ->
            :ok

          {:error, {:already_started, _pid}} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "[WaitChildren] Failed to start child orchestrator for task #{child.id}: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

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

  defp fetch_children([]), do: {:ok, []}

  defp fetch_children(child_ids) when is_list(child_ids) do
    children = Repo.all(from(t in Task, where: t.id in ^child_ids))

    if length(children) == length(child_ids),
      do: {:ok, children},
      else: {:error, :child_not_found}
  end

  defp fetch_children(_), do: {:error, :invalid_child_ids}

  defp all_done_and_not_parked?(children) do
    Enum.all?(children, fn task ->
      not is_nil(task.completed_at) and not has_waiting_execution?(task.id)
    end)
  end

  defp has_waiting_execution?(task_id) do
    Repo.exists?(from(e in StepExecution, where: e.task_id == ^task_id and e.status == "waiting"))
  end
end
