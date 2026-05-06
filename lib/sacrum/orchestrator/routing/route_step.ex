defmodule Sacrum.Orchestrator.Routing.RouteStep do
  @moduledoc """
  Top-level orchestrator for route step transitions.

  The FSM's `:transitioning` handler calls `handle_route_step_transition/2` which
  parses the route output, persists the decision, advances the task to the
  selected destination (intra- or inter-workflow), and returns the next FSM state.
  """

  require Logger

  import Ecto.Query

  alias Sacrum.Orchestrator.{
    ExecutionPool,
    FSMData,
    OutputValidator,
    TaskCompletion,
    WorkflowGraph
  }

  alias Sacrum.Orchestrator.Routing.{InterWorkflow, IntraWorkflow, RouteDecision}
  alias Sacrum.Orchestrator.TaskRuns.{Completion, Lookup}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.TaskWorkflows

  @typep fsm_transition ::
           {:next_state, atom(), FSMData.t()}
           | {:keep_state, FSMData.t()}
           | {:stop, atom(), FSMData.t()}

  @doc """
  Main entry point for handling a route step transition. Returns a gen_statem
  state transition tuple.
  """
  @spec handle_route_step_transition(FSMData.t(), struct()) :: fsm_transition()
  def handle_route_step_transition(data, _current_step) do
    task_id = data.task.id

    with {:ok, execution} <- get_latest_completed_execution(task_id),
         {:ok, decoded} <- RouteDecision.parse_route_output(execution.output),
         :ok <- OutputValidator.validate_routing_contract(decoded),
         {:ok, %{dest_id: dest_id, transition_type: transition_type, handoff: handoff}} <-
           RouteDecision.extract_routing_data(decoded),
         {:ok, route_plan} <- prepare_route_plan(data, dest_id, transition_type, handoff),
         {:ok, %{task: updated_task, route_execution: route_execution}} <-
           commit_route_transition(data, execution, dest_id, transition_type, route_plan) do
      RouteDecision.log_route_decision(
        task_id,
        execution.id,
        dest_id,
        transition_type,
        handoff
      )

      ExecutionPool.release_slot(data.slot_id)
      new_data = %{data | slot_id: nil, pending_handoff: handoff}
      Broadcaster.broadcast_step_execution({:ok, route_execution}, :step_execution_status_changed)
      Broadcaster.broadcast({:ok, updated_task}, :task_updated, :project)

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

  @spec prepare_route_plan(FSMData.t(), binary(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  defp prepare_route_plan(data, dest_id, "intra_workflow", handoff) do
    with {:ok, _dest_step} <- IntraWorkflow.validate_destination_step(data, dest_id),
         :ok <- IntraWorkflow.validate_step_transition_exists(data.task.current_step_id, dest_id),
         {:ok, changeset} <-
           TaskWorkflows.advance_to_step_changeset(data.task, dest_id,
             skip_orchestrator_check: true
           ) do
      preview_task = Ecto.Changeset.apply_changes(changeset)
      decision = TaskCompletion.next_state_decision(preview_task.current_step_id, data)

      {:ok, %{task_changeset: changeset, decision: decision, handoff: handoff}}
    end
  end

  defp prepare_route_plan(data, dest_id, "inter_workflow", handoff) do
    with {:ok, dest_workflow} <- InterWorkflow.validate_destination_workflow(data, dest_id),
         :ok <- InterWorkflow.validate_workflow_transition_exists(data.task.workflow_id, dest_id),
         target_step_id <- InterWorkflow.get_target_step_for_workflow_transition(data, dest_id),
         {:ok, changeset} <-
           InterWorkflow.assign_destination_workflow_changeset(
             data.task,
             dest_workflow,
             target_step_id,
             handoff
           ),
         preview_task = Ecto.Changeset.apply_changes(changeset),
         {:ok, workflow, steps, transitions} <-
           WorkflowGraph.load_workflow_and_graph(data.user_id, preview_task) do
      decision_data = %{
        data
        | task: preview_task,
          workflow: workflow,
          steps: steps,
          transitions: transitions
      }

      decision = TaskCompletion.next_state_decision(preview_task.current_step_id, decision_data)

      {:ok, %{task_changeset: changeset, decision: decision, handoff: handoff}}
    end
  end

  @spec commit_route_transition(FSMData.t(), StepExecution.t(), binary(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  defp commit_route_transition(data, execution, dest_id, transition_type, route_plan) do
    Repo.transaction(fn ->
      with {:ok, route_execution} <-
             execution
             |> RouteDecision.route_decision_changeset(dest_id, transition_type)
             |> Repo.update(),
           {:ok, updated_task} <- Repo.update(route_plan.task_changeset),
           {:ok, changes} <-
             maybe_mark_task_run_completed(data, route_plan.decision, %{
               route_execution: route_execution,
               task: updated_task
             }) do
        changes
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec maybe_mark_task_run_completed(FSMData.t(), tuple(), map()) ::
          {:ok, map()} | {:error, term()}
  defp maybe_mark_task_run_completed(_data, {:next_state, _state}, changes), do: {:ok, changes}
  defp maybe_mark_task_run_completed(_data, {:failed, _reason}, changes), do: {:ok, changes}

  defp maybe_mark_task_run_completed(data, {:stop, _reason, attrs}, changes) do
    case Map.get(data, :task_run_id) do
      nil -> {:ok, changes}
      task_run_id -> mark_task_run_completed(task_run_id, attrs, changes)
    end
  end

  @spec mark_task_run_completed(binary(), map(), map()) :: {:ok, map()} | {:error, term()}
  defp mark_task_run_completed(task_run_id, attrs, changes) do
    with {:ok, task_run} <- Lookup.fetch(task_run_id),
         {:ok, task_run} <-
           task_run
           |> Completion.changeset(attrs)
           |> Repo.update() do
      {:ok, Map.put(changes, :task_run, task_run)}
    end
  end

  @spec get_latest_completed_execution(binary()) ::
          {:ok, StepExecution.t()} | {:error, :no_completed_execution}
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
