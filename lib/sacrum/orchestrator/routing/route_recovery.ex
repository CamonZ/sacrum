defmodule Sacrum.Orchestrator.Routing.RouteRecovery do
  @moduledoc """
  Restores `pending_handoff` and `pending_session` from the TaskRun cursor
  when the orchestrator restarts between advancing the task and dispatching
  its current step.

  A committed deterministic route audit supplies both. Any other completed
  cursor supplies the session directive of the step transition from the
  cursor's step to the current step, if it carries one.

  Recovery is opportunistic: a missing run or cursor leaves FSM data
  unchanged. It fails only when a deterministic audit's recorded destination
  disagrees with the task position from the same transaction.
  """

  alias Sacrum.Orchestrator.Routing.{RouteAudit, RouteProvenance}
  alias Sacrum.Orchestrator.WorkflowGraph

  @type error :: :route_recovery_inconsistent

  @doc """
  Returns FSM data with the persisted handoff and session directive when the
  TaskRun cursor is a committed local route decision, and with the traversed
  step transition's session directive when it is another completed step.
  """
  @spec restore(map()) :: {:ok, map()} | {:error, error()}
  def restore(%{task_run_id: nil} = data), do: {:ok, data}

  def restore(data) do
    case RouteProvenance.fetch_completed_cursor(data) do
      {:ok, {_task_run, execution}} ->
        if RouteAudit.deterministic?(execution),
          do: restore_deterministic(data, execution),
          else: {:ok, restore_transition_session(data, execution)}

      {:error, _reason} ->
        {:ok, data}
    end
  end

  # A directive already held in memory came from the same edge.
  defp restore_transition_session(%{pending_session: nil} = data, %{step_id: step_id})
       when is_binary(step_id) do
    session = WorkflowGraph.transition_session(data, step_id, data.task.current_step_id)
    %{data | pending_session: session}
  end

  defp restore_transition_session(data, _execution), do: data

  defp restore_deterministic(data, execution) do
    with :ok <- validate_destination(execution, data.task),
         {:ok, handoff} <- fetch_handoff(execution) do
      {:ok, %{data | pending_handoff: handoff, pending_session: fetch_session(execution)}}
    end
  end

  defp fetch_handoff(%{handoff: handoff}) when is_map(handoff) or is_nil(handoff),
    do: {:ok, handoff}

  defp fetch_handoff(_execution), do: {:error, :route_recovery_inconsistent}

  defp fetch_session(%{context: %{"route" => %{"session" => session}}}) when is_map(session),
    do: session

  defp fetch_session(_execution), do: nil

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
