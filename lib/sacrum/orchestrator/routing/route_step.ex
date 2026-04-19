defmodule Sacrum.Orchestrator.Routing.RouteStep do
  @moduledoc """
  Top-level orchestrator for route step transitions.

  The FSM's `:transitioning` handler calls `handle_route_step_transition/2` which
  parses the route output, persists the decision, advances the task to the
  selected destination (intra- or inter-workflow), and returns the next FSM state.
  """

  require Logger

  import Ecto.Query

  alias Sacrum.Orchestrator.{ExecutionPool, FSMData, OutputValidator}
  alias Sacrum.Orchestrator.Routing.{InterWorkflow, IntraWorkflow, RouteDecision}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution

  @doc """
  Main entry point for handling a route step transition. Returns a gen_statem
  state transition tuple.
  """
  @spec handle_route_step_transition(FSMData.t(), struct()) ::
          {:next_state, atom(), FSMData.t()}
          | {:keep_state, FSMData.t()}
          | {:stop, atom(), FSMData.t()}
  def handle_route_step_transition(data, _current_step) do
    task_id = data.task.id

    with {:ok, execution} <- get_latest_completed_execution(task_id),
         {:ok, decoded} <- RouteDecision.parse_route_output(execution.output),
         :ok <- OutputValidator.validate_routing_contract(decoded),
         {:ok, %{dest_id: dest_id, transition_type: transition_type, handoff: handoff}} <-
           RouteDecision.extract_routing_data(decoded),
         :ok <-
           RouteDecision.log_route_decision(
             task_id,
             execution.id,
             dest_id,
             transition_type,
             handoff
           ),
         :ok <- RouteDecision.persist_route_decision(execution, dest_id, transition_type),
         {:ok, updated_task} <-
           route_task_to_destination(data, dest_id, transition_type, handoff) do
      ExecutionPool.release_slot(data.slot_id)
      new_data = %{data | slot_id: nil}

      case transition_type do
        "intra_workflow" ->
          IntraWorkflow.handle_intra_route_continuation(new_data, updated_task)

        "inter_workflow" ->
          InterWorkflow.handle_inter_route_continuation(new_data, task_id, updated_task)
      end
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Error in route transition: #{inspect(reason)}"
        )

        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  defp route_task_to_destination(data, dest_id, "intra_workflow", handoff),
    do: IntraWorkflow.handle_intra_workflow_routing(data, dest_id, handoff)

  defp route_task_to_destination(data, dest_id, "inter_workflow", handoff),
    do: InterWorkflow.handle_inter_workflow_routing(data, dest_id, handoff)

  defp get_latest_completed_execution(task_id) do
    query =
      from(e in StepExecution,
        where: e.task_id == ^task_id and e.status == "completed",
        order_by: [desc: e.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:error, :no_completed_execution}
      execution -> {:ok, execution}
    end
  end
end
