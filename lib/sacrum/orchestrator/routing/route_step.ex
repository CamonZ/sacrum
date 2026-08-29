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
    Scheduler,
    StructuredOutput,
    TaskCompletion,
    WorkflowGraph
  }

  alias Sacrum.Orchestrator.Routing.{InterWorkflow, IntraWorkflow, RouteDecision, RouteProvenance}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.TaskWorkflows
  alias Sacrum.Routing.{RouteContext, RouteEvaluator}

  @typep fsm_transition ::
           {:next_state, atom(), FSMData.t()}
           | {:keep_state, FSMData.t()}
           | {:stop, atom(), FSMData.t()}

  @doc """
  Main entry point for handling a route step transition. Returns a gen_statem
  state transition tuple.
  """
  @spec handle_route_step_transition(FSMData.t(), struct()) :: fsm_transition()
  def handle_route_step_transition(data, current_step) do
    task_id = data.task.id

    with {:ok, execution} <- get_latest_completed_execution(task_id),
         {:ok, decoded} <- RouteDecision.parse_route_output(execution.output),
         :ok <- OutputValidator.validate_routing_contract(decoded, current_step.output_schema),
         {:ok, %{dest_id: dest_id, transition_type: transition_type, handoff: handoff}} <-
           RouteDecision.extract_routing_data(decoded),
         {:ok, route_plan} <- prepare_route_plan(data, dest_id, transition_type, handoff),
         {:ok, %{task: updated_task}} <-
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

      handle_route_continuation(new_data, task_id, updated_task, transition_type, route_plan)
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Error in route transition: #{inspect(reason)}"
        )

        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  @doc """
  Evaluates a configured route locally. This path is entered directly from
  `:awaiting_execution`, before any execution-pool allocation or daemon work.
  """
  @spec handle_deterministic_route_step(FSMData.t(), struct(), map()) :: fsm_transition()
  def handle_deterministic_route_step(data, current_step, program) do
    task_id = data.task.id

    with {:ok, provenance} <- RouteProvenance.resolve(data, current_step),
         {:ok, previous_output} <- validated_predecessor_output(provenance),
         {:ok, context} <- build_route_context(data.task, previous_output),
         {:ok, result} <- RouteEvaluator.evaluate(program, context),
         {:ok, {dest_id, transition_type}} <- destination(result.transition),
         {:ok, route_plan} <- prepare_route_plan(data, dest_id, transition_type, result.handoff),
         {:ok, %{task: updated_task}} <-
           commit_route_transition(
             data,
             provenance.source_execution,
             dest_id,
             transition_type,
             route_plan
           ) do
      RouteDecision.log_route_decision(
        task_id,
        provenance.source_execution.id,
        dest_id,
        transition_type,
        result.handoff
      )

      new_data = %{data | pending_handoff: result.handoff}
      handle_route_continuation(new_data, task_id, updated_task, transition_type, route_plan)
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Error in deterministic route transition: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  defp validated_predecessor_output(%{source_execution: execution, source_step: source_step}) do
    with {:ok, output} <- decode_predecessor_output(execution.output),
         :ok <- OutputValidator.validate_output(output, source_step.output_schema) do
      {:ok, output}
    end
  end

  defp decode_predecessor_output(output) when is_binary(output),
    do: StructuredOutput.decode(output)

  defp decode_predecessor_output(_output), do: {:error, :route_predecessor_output_missing}

  defp build_route_context(task, previous_output) do
    RouteContext.build(
      previous_output,
      %{"level" => task.level, "tags" => task.tags || []},
      1
    )
  end

  defp destination(%{type: :intra_workflow, step_id: step_id}),
    do: {:ok, {step_id, "intra_workflow"}}

  defp destination(%{type: :inter_workflow, workflow_id: workflow_id}),
    do: {:ok, {workflow_id, "inter_workflow"}}

  @spec prepare_route_plan(FSMData.t(), binary(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  defp prepare_route_plan(data, dest_id, "intra_workflow", handoff) do
    with {:ok, _dest_step} <- IntraWorkflow.validate_destination_step(data, dest_id),
         :ok <- IntraWorkflow.validate_step_transition_exists(data.task.current_step_id, dest_id),
         :ok <- WorkflowGraph.validate_stop_destination(data, dest_id),
         {:ok, changeset} <-
           TaskWorkflows.advance_to_step_changeset(data.task, dest_id,
             skip_orchestrator_check: true
           ) do
      preview_task = Ecto.Changeset.apply_changes(changeset)
      decision = TaskCompletion.next_state_decision(preview_task.current_step_id, data)

      {:ok,
       %{
         task_changeset: changeset,
         decision: decision,
         handoff: handoff
       }}
    end
  end

  defp prepare_route_plan(data, dest_id, "inter_workflow", handoff) do
    with {:ok, dest_workflow} <- InterWorkflow.validate_destination_workflow(data, dest_id),
         :ok <- InterWorkflow.validate_workflow_transition_exists(data.task.workflow_id, dest_id),
         {:ok, %{changeset: changeset, target_step: _target_step}} <-
           InterWorkflow.assign_destination_workflow_plan(
             data.task,
             dest_workflow,
             InterWorkflow.get_target_step_for_workflow_transition(data, dest_id)
           ) do
      preview_task = Ecto.Changeset.apply_changes(changeset)

      with {:ok, decision} <- inter_workflow_next_state_decision(data, preview_task) do
        {:ok,
         %{
           task_changeset: changeset,
           decision: decision,
           handoff: handoff
         }}
      end
    end
  end

  @spec handle_route_continuation(FSMData.t(), binary(), struct(), String.t(), map()) ::
          fsm_transition()
  defp handle_route_continuation(
         new_data,
         task_id,
         updated_task,
         _transition_type,
         %{decision: {:stop, :normal, %{outcome_kind: "completed"}}}
       ) do
    :ok = Scheduler.notify_task_completed(task_id, %{status: "completed"})
    {:stop, :normal, %{new_data | task: updated_task}}
  end

  defp handle_route_continuation(new_data, _task_id, updated_task, "intra_workflow", _route_plan) do
    IntraWorkflow.handle_intra_route_continuation(new_data, updated_task)
  end

  defp handle_route_continuation(new_data, task_id, updated_task, "inter_workflow", _route_plan) do
    InterWorkflow.handle_inter_route_continuation(new_data, task_id, updated_task)
  end

  @spec inter_workflow_next_state_decision(FSMData.t(), struct()) ::
          {:ok, tuple()} | {:error, term()}
  defp inter_workflow_next_state_decision(data, preview_task) do
    with {:ok, workflow, steps, transitions} <-
           WorkflowGraph.load_validated_workflow_and_graph(data.user_id, preview_task) do
      decision_data = %{
        data
        | task: preview_task,
          workflow: workflow,
          steps: steps,
          transitions: transitions
      }

      with :ok <-
             WorkflowGraph.validate_stop_destination(
               decision_data,
               preview_task.current_step_id
             ) do
        {:ok, TaskCompletion.next_state_decision(preview_task.current_step_id, decision_data)}
      end
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
             maybe_finish_route_task_and_run(data, updated_task, route_plan, %{
               route_execution: route_execution,
               task: updated_task
             }) do
        changes
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec maybe_finish_route_task_and_run(FSMData.t(), struct(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  defp maybe_finish_route_task_and_run(data, _updated_task, route_plan, changes) do
    TaskCompletion.maybe_mark_task_run_completed_for_decision(data, route_plan.decision, changes)
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
