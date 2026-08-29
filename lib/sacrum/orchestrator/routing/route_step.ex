defmodule Sacrum.Orchestrator.Routing.RouteStep do
  @moduledoc """
  Route-step orchestration for both local deterministic evaluation and the
  isolated prompt-driven fallback.

  Configured routes are entered from `:awaiting_execution` before any
  execution-pool allocation. Unconfigured routes still complete through the
  daemon path, then share the same plan/commit/continue spine.
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

  alias Sacrum.Orchestrator.Routing.{
    InterWorkflow,
    IntraWorkflow,
    RouteAudit,
    RouteDecision,
    RouteProvenance
  }

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}
  alias Sacrum.Repo.TaskWorkflows
  alias Sacrum.Routing.{RouteContext, RouteEvaluator}

  @typep fsm_transition ::
           {:next_state, atom(), FSMData.t()}
           | {:keep_state, FSMData.t()}
           | {:stop, atom(), FSMData.t()}

  @doc """
  Completes a prompt-driven route after daemon execution.
  """
  @spec handle_route_step_transition(FSMData.t(), struct()) :: fsm_transition()
  def handle_route_step_transition(data, current_step) do
    with {:ok, execution} <- get_latest_completed_execution(data.task.id),
         {:ok, decoded} <- RouteDecision.parse_route_output(execution.output),
         :ok <- OutputValidator.validate_routing_contract(decoded, current_step.output_schema),
         {:ok, %{dest_id: dest_id, transition_type: transition_type, handoff: handoff}} <-
           RouteDecision.extract_routing_data(decoded),
         {:ok, route_plan} <- prepare_route_plan(data, dest_id, transition_type, handoff),
         {:ok, committed} <-
           commit_route_transition(
             data,
             route_plan,
             {:update,
              RouteDecision.route_decision_changeset(execution, dest_id, transition_type)}
           ) do
      complete_committed_route(data, committed, dest_id, transition_type, handoff, route_plan)
    else
      {:error, reason} -> fail_route(data, reason, "Error in route transition")
    end
  end

  @doc """
  Evaluates a configured route locally before any execution-pool allocation.
  """
  @spec handle_deterministic_route_step(FSMData.t(), struct(), map()) :: fsm_transition()
  def handle_deterministic_route_step(data, current_step, program) do
    with {:ok, provenance} <- RouteProvenance.resolve(data, current_step),
         {:ok, previous_output} <- validated_predecessor_output(provenance),
         {:ok, context} <- build_route_context(data.task, current_step.id, previous_output),
         {:ok, result} <- RouteEvaluator.evaluate(program, context),
         {:ok, {dest_id, transition_type}} <- destination(result.transition),
         {:ok, route_plan} <- prepare_route_plan(data, dest_id, transition_type, result.handoff),
         {:ok, committed} <-
           commit_route_transition(
             data,
             route_plan,
             {:insert,
              local_route_execution_changeset(
                data,
                provenance,
                program,
                context,
                result,
                dest_id,
                transition_type
              ), provenance.task_run}
           ) do
      complete_committed_route(
        data,
        committed,
        dest_id,
        transition_type,
        result.handoff,
        route_plan
      )
    else
      {:error, reason} -> fail_route(data, reason, "Error in deterministic route transition")
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

  defp build_route_context(task, route_step_id, previous_output) do
    RouteContext.build(
      previous_output,
      %{"level" => task.level, "tags" => task.tags || []},
      RouteAudit.visit_count(task, route_step_id)
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

  defp commit_route_transition(data, route_plan, persist) do
    Repo.transaction(fn ->
      with {:ok, acc} <- persist_route_execution(persist),
           {:ok, updated_task} <- Repo.update(route_plan.task_changeset),
           {:ok, changes} <-
             maybe_finish_route_task_and_run(
               data,
               updated_task,
               route_plan,
               Map.put(acc, :task, updated_task)
             ) do
        changes
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp persist_route_execution({:update, changeset}) do
    with {:ok, route_execution} <- Repo.update(changeset) do
      {:ok, %{route_execution: route_execution}}
    end
  end

  defp persist_route_execution({:insert, changeset, task_run}) do
    with {:ok, route_execution} <- Repo.insert(changeset),
         {:ok, task_run} <- update_route_cursor(task_run, route_execution.id) do
      {:ok, %{route_execution: route_execution, task_run: task_run}}
    end
  end

  defp local_route_execution_changeset(
         data,
         provenance,
         program,
         context,
         result,
         dest_id,
         transition_type
       ) do
    step = provenance.route_step

    StepExecution.create_changeset(
      %StepExecution{user_id: data.user_id, project_id: data.project_id},
      %{
        task_id: data.task.id,
        task_run_id: provenance.task_run.id,
        workflow_id: data.task.workflow_id,
        step_id: step.id,
        step_name: step.name,
        step_type: :route,
        status: "completed",
        context: RouteAudit.context(provenance, program, context, result),
        transition_result: RouteDecision.transition_result(dest_id, transition_type),
        handoff: result.handoff
      }
    )
  end

  defp update_route_cursor(task_run, route_execution_id) do
    task_run
    |> TaskRun.update_changeset(%{latest_step_execution_id: route_execution_id})
    |> Repo.update()
  end

  defp complete_committed_route(
         data,
         %{task: updated_task, route_execution: route_execution},
         dest_id,
         transition_type,
         handoff,
         route_plan
       ) do
    RouteDecision.log_route_decision(
      data.task.id,
      route_execution.id,
      dest_id,
      transition_type,
      handoff
    )

    if data.slot_id, do: ExecutionPool.release_slot(data.slot_id)

    handle_route_continuation(
      %{data | slot_id: nil, pending_handoff: handoff},
      data.task.id,
      updated_task,
      transition_type,
      route_plan
    )
  end

  defp fail_route(data, reason, message) do
    Logger.error("[TaskOrchestrator:#{data.task.id}] #{message}: #{inspect(reason)}")

    if data.slot_id, do: ExecutionPool.release_slot(data.slot_id)

    {:next_state, :failed, %{data | slot_id: nil}}
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
