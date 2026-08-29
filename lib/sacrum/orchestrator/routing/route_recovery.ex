defmodule Sacrum.Orchestrator.Routing.RouteRecovery do
  @moduledoc """
  Restores the handoff from an already committed deterministic route decision.

  Recovery reads the TaskRun cursor rather than reevaluating a route from the
  task's mutable position. A deterministic route execution is only useful when
  its recorded destination still agrees with the task position reached by the
  same transaction.
  """

  alias Sacrum.Orchestrator.TaskRuns.Lookup
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution

  @type error :: :route_recovery_inconsistent | :task_run_not_found

  @doc """
  Returns FSM data with the deterministic route's persisted handoff when the
  current TaskRun cursor is a committed local route decision. Non-route cursors
  are ordinary executions and leave the FSM data unchanged.
  """
  @spec restore(map()) :: {:ok, map()} | {:error, error()}
  def restore(%{task_run_id: nil} = data), do: {:ok, data}

  def restore(data) do
    with {:ok, task_run} <-
           Lookup.fetch_for_task(data.user_id, data.project_id, data.task.id, data.task_run_id),
         {:ok, route_execution} <- fetch_deterministic_cursor(task_run, data),
         :ok <- validate_destination(route_execution, data.task),
         handoff when is_map(handoff) <- route_execution.handoff do
      {:ok, %{data | pending_handoff: handoff}}
    else
      :not_deterministic_route -> {:ok, data}
      _ -> {:error, :route_recovery_inconsistent}
    end
  end

  defp fetch_deterministic_cursor(%{latest_step_execution_id: nil}, _data),
    do: :not_deterministic_route

  defp fetch_deterministic_cursor(task_run, data) do
    execution =
      Repo.get_by(StepExecution,
        id: task_run.latest_step_execution_id,
        user_id: data.user_id,
        project_id: data.project_id,
        task_id: data.task.id,
        task_run_id: task_run.id,
        step_type: :route,
        status: "completed"
      )

    if deterministic_route_execution?(execution),
      do: {:ok, execution},
      else: :not_deterministic_route
  end

  defp deterministic_route_execution?(%StepExecution{
         context: %{"route" => %{"mode" => "deterministic", "source_execution_id" => source_id}}
       })
       when is_binary(source_id),
       do: true

  defp deterministic_route_execution?(_execution), do: false

  defp validate_destination(execution, task) do
    with {:ok, %{"dest_id" => destination, "transition_type" => transition_type}} <-
           decode_transition_result(execution.transition_result),
         true <- destination_matches_task?(transition_type, destination, execution, task) do
      :ok
    else
      _ -> {:error, :route_recovery_inconsistent}
    end
  end

  defp decode_transition_result(result) when is_binary(result), do: Jason.decode(result)
  defp decode_transition_result(_result), do: {:error, :invalid_transition_result}

  defp destination_matches_task?("intra_workflow", destination, execution, task) do
    destination == task.current_step_id and execution.workflow_id == task.workflow_id
  end

  defp destination_matches_task?("inter_workflow", destination, _execution, task) do
    destination == task.workflow_id
  end

  defp destination_matches_task?(_transition_type, _destination, _execution, _task), do: false
end
