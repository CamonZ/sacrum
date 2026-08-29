defmodule Sacrum.Orchestrator.Routing.RouteRecovery do
  @moduledoc """
  Restores `pending_handoff` from a committed deterministic route audit.

  Recovery is opportunistic: a missing run or a non-route cursor leaves FSM
  data unchanged. It fails only when a deterministic audit's recorded
  destination disagrees with the task position from the same transaction.
  """

  alias Sacrum.Orchestrator.Routing.{RouteAudit, RouteProvenance}

  @type error :: :route_recovery_inconsistent

  @doc """
  Returns FSM data with the persisted handoff when the TaskRun cursor is a
  committed local route decision. Ordinary cursors are left unchanged.
  """
  @spec restore(map()) :: {:ok, map()} | {:error, error()}
  def restore(%{task_run_id: nil} = data), do: {:ok, data}

  def restore(data) do
    case load_deterministic_cursor(data) do
      {:ok, execution} -> restore_deterministic(data, execution)
      :none -> {:ok, data}
    end
  end

  defp load_deterministic_cursor(data) do
    case RouteProvenance.fetch_completed_cursor(data) do
      {:ok, {_task_run, execution}} ->
        if RouteAudit.deterministic?(execution), do: {:ok, execution}, else: :none

      {:error, _reason} ->
        :none
    end
  end

  defp restore_deterministic(data, execution) do
    with :ok <- validate_destination(execution, data.task),
         {:ok, handoff} <- fetch_handoff(execution) do
      {:ok, %{data | pending_handoff: handoff}}
    end
  end

  defp fetch_handoff(%{handoff: handoff}) when is_map(handoff), do: {:ok, handoff}
  defp fetch_handoff(_execution), do: {:error, :route_recovery_inconsistent}

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
