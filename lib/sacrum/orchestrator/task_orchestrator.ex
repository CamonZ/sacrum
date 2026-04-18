defmodule Sacrum.Orchestrator.TaskOrchestrator do
  @moduledoc """
  Gen_statem for driving a task through its entire workflow lifecycle.

  States:
  - :initializing - Load workflow graph from DB, build steps/transitions maps
  - :awaiting_execution - Request pool slot, wait for grant
  - :executing - Create StepExecution, subscribe to PubSub, wait for daemon completion
  - :transitioning - Select next step, advance task, release pool slot
  - :completing - Mark task complete
  - :completed - Notify scheduler, stop
  - :failed - Release pool slot, stop

  Uses handle_event_function with state_enter enabled.
  Enter callbacks handle setup/logging and schedule :state_timeout for work.
  State timeout handlers do the actual work and can transition states.
  Registered via TaskRegistry: {:via, Registry, {Sacrum.Orchestrator.TaskRegistry, task_id}}
  """

  @behaviour :gen_statem

  require Logger
  import Ecto.Query

  alias Ecto.{Changeset, Multi}
  alias Sacrum.Accounts

  alias Sacrum.Orchestrator.{
    ExecutionDispatcher,
    ExecutionPool,
    OutputValidator,
    PromptRenderer,
    Scheduler,
    StructuredOutput
  }

  alias Sacrum.Repo

  alias Sacrum.Repo.Schemas.{
    StepExecution,
    StepTransition,
    Task,
    Workflow,
    WorkflowStep,
    WorkflowTransition
  }

  alias Sacrum.Repo.TaskWorkflows

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    user_id = Keyword.fetch!(opts, :user_id)

    :gen_statem.start_link(
      {:via, Registry, {Sacrum.Orchestrator.TaskRegistry, task_id}},
      __MODULE__,
      {user_id, task_id},
      []
    )
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :task_id)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary,
      shutdown: 5000
    }
  end

  @impl :gen_statem
  def callback_mode do
    [:handle_event_function, :state_enter]
  end

  @impl :gen_statem
  def init({user_id, task_id}) do
    case Repo.get(Task, task_id) do
      nil ->
        Logger.error("[TaskOrchestrator:#{task_id}] Task not found")
        :stop

      task ->
        data = %{
          user_id: user_id,
          task: task,
          project_id: task.project_id,
          workflow: nil,
          steps: %{},
          transitions: %{},
          current_execution_id: nil,
          slot_id: nil,
          subscribed: false
        }

        Logger.info(
          "[TaskOrchestrator:#{task_id}] Starting in :initializing state user=#{user_id} project=#{task.project_id} workflow=#{inspect(task.workflow_id)} current_step=#{inspect(task.current_step_id)}"
        )

        {:ok, :initializing, data}
    end
  end

  @impl :gen_statem
  # Catches every exit path — normal stops, crashes, and shutdowns — so a
  # supervisor-killed or exception-terminated process still leaves a trace.
  # Without this, 6304d1b9-style "process gone, no observable error" incidents
  # are impossible to diagnose from logs alone.
  def terminate(reason, state, %{task: task} = data) do
    task_id = task.id

    case reason do
      :normal ->
        Logger.info(
          "[TaskOrchestrator:#{task_id}] terminate reason=:normal state=#{inspect(state)} " <>
            "current_step=#{inspect(task.current_step_id)} slot_id=#{inspect(data.slot_id)}"
        )

      :shutdown ->
        Logger.warning(
          "[TaskOrchestrator:#{task_id}] terminate reason=:shutdown state=#{inspect(state)} " <>
            "current_step=#{inspect(task.current_step_id)} slot_id=#{inspect(data.slot_id)}"
        )

      {:shutdown, _} ->
        Logger.warning(
          "[TaskOrchestrator:#{task_id}] terminate reason=#{inspect(reason)} state=#{inspect(state)} " <>
            "current_step=#{inspect(task.current_step_id)} slot_id=#{inspect(data.slot_id)}"
        )

      _ ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] ABNORMAL terminate reason=#{inspect(reason)} " <>
            "state=#{inspect(state)} current_step=#{inspect(task.current_step_id)} " <>
            "slot_id=#{inspect(data.slot_id)} current_execution=#{inspect(data.current_execution_id)}"
        )
    end

    if data.slot_id do
      Logger.info("[TaskOrchestrator:#{task_id}] terminate releasing leaked slot #{data.slot_id}")
      ExecutionPool.release_slot(data.slot_id)
    end

    :ok
  end

  def terminate(reason, state, _data) do
    Logger.error(
      "[TaskOrchestrator] terminate without data reason=#{inspect(reason)} state=#{inspect(state)}"
    )

    :ok
  end

  # ===== ENTER CALLBACKS =====
  # Enter callbacks log the transition and schedule :state_timeout for states
  # that need to do work immediately. States that wait for external events
  # (:executing) do setup in enter and then wait.

  @impl :gen_statem
  def handle_event(:enter, prev_state, state, data)
      when state in [:initializing, :awaiting_execution, :transitioning, :completing] do
    Logger.info("[TaskOrchestrator:#{data.task.id}] enter #{prev_state} -> #{state}")
    {:keep_state_and_data, [{:state_timeout, 0, :run}]}
  end

  def handle_event(:enter, prev_state, :executing, data) do
    task_id = data.task.id

    Logger.info(
      "[TaskOrchestrator:#{task_id}] enter #{prev_state} -> :executing, step=#{data.task.current_step_id}"
    )

    with {:ok, task} <- reload_task(data.task.id),
         {:ok, current_step} <- get_current_step(data),
         {:ok, execution} <-
           ExecutionDispatcher.create_and_dispatch(data.user_id, task, current_step.id) do
      data = %{data | task: task}

      unless data.subscribed do
        :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{data.project_id}")

        Logger.info(
          "[TaskOrchestrator:#{task_id}] Subscribed to project:#{data.project_id} PubSub"
        )
      end

      new_data = %{data | current_execution_id: execution.id, subscribed: true}

      Logger.info(
        "[TaskOrchestrator:#{task_id}] Created execution #{execution.id} step=#{current_step.id} (#{current_step.name}), waiting for daemon"
      )

      {:keep_state, new_data}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to dispatch execution: #{inspect(reason)}"
        )

        {:keep_state, data, [{:state_timeout, 0, :fail}]}
    end
  end

  def handle_event(:enter, prev_state, :completed, data) do
    task_id = data.task.id

    Logger.info(
      "[TaskOrchestrator:#{task_id}] enter #{prev_state} -> :completed, notifying scheduler"
    )

    Scheduler.notify_task_completed(task_id, %{status: "completed"})
    Logger.info("[TaskOrchestrator:#{task_id}] Completed, stopping")
    {:stop, :normal, data}
  end

  def handle_event(:enter, prev_state, :failed, data) do
    task_id = data.task.id
    Logger.error("[TaskOrchestrator:#{task_id}] enter #{prev_state} -> :failed")

    if data.slot_id do
      Logger.info("[TaskOrchestrator:#{task_id}] Releasing pool slot #{data.slot_id}")
      ExecutionPool.release_slot(data.slot_id)
    end

    Logger.error("[TaskOrchestrator:#{task_id}] Failed, stopping")
    {:stop, :normal, data}
  end

  # ===== STATE TIMEOUT HANDLERS =====
  # These do the actual work and can transition states.

  # :fail timeout — used by :executing enter callbacks when setup fails
  def handle_event(:state_timeout, :fail, :executing, data) do
    Logger.error("[TaskOrchestrator:#{data.task.id}] Setup failed in :executing, -> :failed")
    {:next_state, :failed, data}
  end

  def handle_event(:state_timeout, :run, :initializing, data) do
    task_id = data.task.id

    Logger.info(
      "[TaskOrchestrator:#{task_id}] :initializing :run - loading workflow #{data.task.workflow_id}"
    )

    case load_workflow_and_graph(data.user_id, data.task) do
      {:ok, workflow, steps, transitions} ->
        Logger.info(
          "[TaskOrchestrator:#{task_id}] Loaded workflow #{workflow.id} with #{map_size(steps)} steps"
        )

        new_data = %{
          data
          | workflow: workflow,
            steps: steps,
            transitions: transitions
        }

        Logger.info("[TaskOrchestrator:#{task_id}] -> :awaiting_execution")
        {:next_state, :awaiting_execution, new_data}

      {:error, reason} ->
        Logger.error("[TaskOrchestrator:#{task_id}] Failed to load workflow: #{inspect(reason)}")
        {:next_state, :failed, data}
    end
  end

  def handle_event(:state_timeout, :run, :awaiting_execution, data) do
    task_id = data.task.id
    Logger.info("[TaskOrchestrator:#{task_id}] :awaiting_execution :run - requesting pool slot")

    case ExecutionPool.request_slot(self()) do
      {:ok, slot_id} ->
        Logger.info("[TaskOrchestrator:#{task_id}] Got pool slot #{slot_id}, -> :executing")
        {:next_state, :executing, %{data | slot_id: slot_id}}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to request pool slot: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  def handle_event(:state_timeout, :run, :transitioning, data) do
    task_id = data.task.id

    Logger.info("[TaskOrchestrator:#{task_id}] :transitioning :run")

    case get_current_step(data) do
      {:ok, current_step} ->
        case current_step.step_type do
          "route" ->
            handle_route_step_transition(data, current_step)

          type when type in ["execute", "evaluate"] ->
            handle_single_transition_step(data, current_step)

          other ->
            Logger.error("[TaskOrchestrator:#{task_id}] Unknown step type: #{other}")
            ExecutionPool.release_slot(data.slot_id)
            {:next_state, :failed, %{data | slot_id: nil}}
        end

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Error getting current step: #{inspect(reason)}"
        )

        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  def handle_event(:state_timeout, :run, :completing, data) do
    task_id = data.task.id
    Logger.info("[TaskOrchestrator:#{task_id}] :completing :run")

    case handle_completion(data) do
      {:ok, :completed, new_data} ->
        Logger.info("[TaskOrchestrator:#{task_id}] Workflow complete, -> :completed")
        {:next_state, :completed, new_data}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Error handling completion: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  # ===== INFO HANDLERS (PubSub) =====

  def handle_event(:info, message, :executing, data) do
    case message do
      %Phoenix.Socket.Broadcast{
        event: "step_execution_status_changed",
        payload: %{id: execution_id, status: status}
      } ->
        Logger.info(
          "[TaskOrchestrator:#{data.task.id}] PubSub step_execution_status_changed: exec=#{execution_id} status=#{status}"
        )

        handle_execution_status_changed(execution_id, status, data)

      %Phoenix.Socket.Broadcast{event: event} ->
        Logger.debug(
          "[TaskOrchestrator:#{data.task.id}] Ignoring PubSub event #{event} in :executing"
        )

        :keep_state_and_data

      other ->
        Logger.debug(
          "[TaskOrchestrator:#{data.task.id}] Ignoring :info message in :executing: #{inspect(other)}"
        )

        :keep_state_and_data
    end
  end

  # Catch-all for unhandled events in any state
  def handle_event(event_type, event_content, state, data) do
    Logger.warning(
      "[TaskOrchestrator:#{data.task.id}] Unhandled event type=#{inspect(event_type)} content=#{inspect(event_content)} state=#{inspect(state)}"
    )

    :keep_state_and_data
  end

  # ===== TRANSITION HANDLERS =====

  defp handle_single_transition_step(data, current_step) do
    task_id = data.task.id

    next_transitions = get_outgoing_transitions(data, current_step.id)

    with {:ok, next_step_id} <- select_single_transition(next_transitions),
         {:ok, updated_task} <- TaskWorkflows.advance_to_step(data.task, next_step_id) do
      ExecutionPool.release_slot(data.slot_id)
      new_data = %{data | task: updated_task, slot_id: nil}
      determine_next_state(next_step_id, new_data)
    else
      {:error, :no_outgoing_transitions} ->
        Logger.info("[TaskOrchestrator:#{task_id}] No outgoing transitions, treating as final")
        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :completing, %{data | slot_id: nil}}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Error in single transition: #{inspect(reason)}"
        )

        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  defp handle_route_step_transition(data, _current_step) do
    task_id = data.task.id

    with {:ok, execution} <- get_latest_execution(task_id),
         {:ok, decoded} <- parse_route_output(execution.output),
         :ok <- OutputValidator.validate_routing_contract(decoded),
         {:ok, %{dest_id: dest_id, transition_type: transition_type, handoff: handoff}} <-
           extract_routing_data(decoded),
         _ <- log_route_decision(task_id, execution.id, dest_id, transition_type, handoff),
         :ok <- persist_route_decision(execution, dest_id, transition_type),
         {:ok, updated_task} <-
           route_task_to_destination(data, dest_id, transition_type, handoff) do
      ExecutionPool.release_slot(data.slot_id)

      case transition_type do
        "intra_workflow" ->
          handle_intra_route_continuation(data, updated_task)

        "inter_workflow" ->
          handle_inter_route_continuation(data, task_id, updated_task)
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

  defp extract_routing_data(decoded) when is_map(decoded) do
    case {Map.get(decoded, "transition_to"), Map.get(decoded, "transition_type")} do
      {dest_id, type}
      when is_binary(dest_id) and type in ["intra_workflow", "inter_workflow"] ->
        {:ok,
         %{
           dest_id: dest_id,
           transition_type: type,
           handoff: Map.get(decoded, "handoff")
         }}

      _ ->
        {:error, :invalid_route_output_format}
    end
  end

  defp extract_routing_data(_decoded) do
    {:error, :route_output_not_map}
  end

  # Persisted before routing so the decision survives downstream failures for forensics.
  defp persist_route_decision(execution, dest_id, transition_type) do
    transition_result =
      Jason.encode!(%{"dest_id" => dest_id, "transition_type" => transition_type})

    case Accounts.StepExecutions.update(execution, %{transition_result: transition_result}) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator] persist_route_decision failed execution=#{execution.id} " <>
            "dest_id=#{dest_id} transition_type=#{transition_type} reason=#{inspect(reason)}"
        )

        {:error, {:route_decision_persist_failed, reason}}
    end
  end

  defp log_route_decision(task_id, execution_id, dest_id, transition_type, handoff) do
    handoff_keys =
      case handoff do
        m when is_map(m) -> Map.keys(m)
        _ -> nil
      end

    Logger.info(
      "[TaskOrchestrator:#{task_id}] route decision execution=#{execution_id} " <>
        "dest_id=#{dest_id} transition_type=#{transition_type} handoff_keys=#{inspect(handoff_keys)}"
    )
  end

  defp handle_intra_route_continuation(data, updated_task) do
    # Same workflow - can use existing workflow/steps cache
    new_data = %{data | task: updated_task, slot_id: nil}
    determine_next_state(updated_task.current_step_id, new_data)
  end

  defp handle_inter_route_continuation(data, task_id, updated_task) do
    # Different workflow - must reload workflow graph
    case load_workflow_and_graph(data.user_id, updated_task) do
      {:ok, workflow, steps, transitions} ->
        new_data = %{
          data
          | task: updated_task,
            workflow: workflow,
            steps: steps,
            transitions: transitions,
            slot_id: nil
        }

        determine_next_state(updated_task.current_step_id, new_data)

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to reload workflow after inter-workflow routing: #{inspect(reason)}"
        )

        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  defp parse_route_output(nil) do
    Logger.warning("[TaskOrchestrator] parse_route_output got nil output on route step")
    {:error, :missing_route_output}
  end

  defp parse_route_output(output) when is_binary(output) do
    case StructuredOutput.decode(output) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        Logger.warning(
          "[TaskOrchestrator] parse_route_output decode failed reason=#{inspect(reason)} " <>
            "output_preview=#{inspect(String.slice(output, 0, 200))}"
        )

        {:error, :invalid_json_output}
    end
  end

  defp get_latest_execution(task_id) do
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

  defp route_task_to_destination(data, dest_id, "intra_workflow", handoff) do
    handle_intra_workflow_routing(data, dest_id, handoff)
  end

  defp route_task_to_destination(data, dest_id, "inter_workflow", handoff) do
    handle_inter_workflow_routing(data, dest_id, handoff)
  end

  defp handle_intra_workflow_routing(data, dest_step_id, handoff) do
    task_id = data.task.id

    with {:ok, _dest_step} <- validate_destination_step(data, dest_step_id),
         :ok <- validate_step_transition_exists(data.task.current_step_id, dest_step_id),
         {:ok, updated_task} <- TaskWorkflows.advance_to_step(data.task, dest_step_id, handoff) do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Route step routed intra_workflow from #{data.task.current_step_id} to #{dest_step_id} handoff=#{inspect(handoff != nil)}"
      )

      {:ok, updated_task}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Intra-workflow routing failed: #{inspect(reason)} " <>
            "from=#{data.task.current_step_id} to=#{dest_step_id}"
        )

        {:error, reason}
    end
  end

  defp handle_inter_workflow_routing(data, dest_workflow_id, handoff) do
    task_id = data.task.id

    with {:ok, dest_workflow} <- validate_destination_workflow(data, dest_workflow_id),
         :ok <- validate_workflow_transition_exists(data.task.workflow_id, dest_workflow_id),
         target_step_id <- get_target_step_for_workflow_transition(data, dest_workflow_id),
         {:ok, updated_task} <-
           assign_destination_workflow(data.task, dest_workflow, target_step_id, handoff) do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Route step routed inter_workflow to workflow #{dest_workflow_id}"
      )

      {:ok, updated_task}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Inter-workflow routing failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp validate_destination_step(data, step_id) do
    case Repo.get(WorkflowStep, step_id) do
      nil ->
        {:error, :destination_step_not_found}

      step ->
        if step.project_id == data.project_id and step.user_id == data.user_id do
          {:ok, step}
        else
          {:error, :destination_step_cross_project_or_user}
        end
    end
  end

  defp validate_destination_workflow(data, workflow_id) do
    case Repo.get(Workflow, workflow_id) do
      nil ->
        {:error, :destination_workflow_not_found}

      workflow ->
        if workflow.project_id == data.project_id and workflow.user_id == data.user_id do
          {:ok, workflow}
        else
          {:error, :destination_workflow_cross_project_or_user}
        end
    end
  end

  defp validate_step_transition_exists(from_step_id, to_step_id) do
    query =
      from(t in StepTransition,
        where: t.from_step_id == ^from_step_id and t.to_step_id == ^to_step_id
      )

    case Repo.one(query) do
      nil -> {:error, :no_step_transition}
      _transition -> :ok
    end
  end

  defp validate_workflow_transition_exists(from_workflow_id, to_workflow_id) do
    query =
      from(t in WorkflowTransition,
        where: t.from_workflow_id == ^from_workflow_id and t.to_workflow_id == ^to_workflow_id
      )

    case Repo.one(query) do
      nil -> {:error, :no_workflow_transition}
      _transition -> :ok
    end
  end

  defp get_target_step_for_workflow_transition(data, to_workflow_id) do
    query =
      from(t in WorkflowTransition,
        where:
          t.from_workflow_id == ^data.task.workflow_id and
            t.to_workflow_id == ^to_workflow_id,
        select: t.target_step_id
      )

    Repo.one(query)
  end

  defp assign_destination_workflow(task, dest_workflow, target_step_id, handoff) do
    dest_workflow = Repo.preload(dest_workflow, :workflow_steps)

    with {:ok, target_step} <- resolve_target_step(dest_workflow, target_step_id) do
      do_assign_destination_workflow(task, dest_workflow, target_step, handoff)
    end
  end

  defp resolve_target_step(_workflow, step_id) when not is_nil(step_id) do
    case Repo.get(WorkflowStep, step_id) do
      nil -> {:error, :target_step_not_found}
      step -> {:ok, step}
    end
  end

  defp resolve_target_step(workflow, nil) do
    case workflow.initial_step_id do
      nil ->
        case Enum.sort_by(workflow.workflow_steps, & &1.step_order) do
          [first | _] -> {:ok, first}
          [] -> {:error, :destination_workflow_has_no_steps}
        end

      step_id ->
        case Repo.get(WorkflowStep, step_id) do
          nil -> {:error, :initial_step_not_found}
          step -> {:ok, step}
        end
    end
  end

  defp do_assign_destination_workflow(task, dest_workflow, target_step, handoff) do
    step_exec_attrs = %{
      task_id: task.id,
      workflow_id: dest_workflow.id,
      step_name: target_step.name,
      status: "entered",
      handoff: handoff
    }

    multi =
      Multi.new()
      |> Multi.update(
        :task,
        Changeset.change(task, %{
          workflow_id: dest_workflow.id,
          current_step_id: target_step.id
        })
      )
      |> Multi.insert(
        :step_execution,
        StepExecution.create_changeset(
          %StepExecution{
            user_id: task.user_id,
            project_id: task.project_id
          },
          step_exec_attrs
        )
      )

    case Repo.transaction(multi) do
      {:ok, %{task: updated_task, step_execution: execution}} ->
        Logger.info(
          "[TaskOrchestrator:#{task.id}] Assigned destination workflow=#{dest_workflow.id} " <>
            "target_step=#{target_step.id} (#{target_step.name}) execution=#{execution.id} " <>
            "handoff=#{inspect(handoff != nil)}"
        )

        {:ok, updated_task}

      {:error, op, changeset, _changes} ->
        Logger.error(
          "[TaskOrchestrator:#{task.id}] Assign destination workflow failed op=#{inspect(op)} " <>
            "dest_workflow=#{dest_workflow.id} errors=#{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  # ===== PRIVATE HELPERS =====

  defp determine_next_state(nil, data) do
    Logger.error("[TaskOrchestrator:#{data.task.id}] No current step after transition")
    {:next_state, :failed, data}
  end

  defp determine_next_state(next_step_id, data) do
    task_id = data.task.id

    case data.steps[next_step_id] do
      nil ->
        Logger.error("[TaskOrchestrator:#{task_id}] Step #{next_step_id} not found in cache")
        {:next_state, :failed, data}

      %{is_final: true} ->
        Logger.info("[TaskOrchestrator:#{task_id}] Next step is final")
        {:next_state, :completing, data}

      _step when data.workflow.auto_advance ->
        Logger.info("[TaskOrchestrator:#{task_id}] Auto-advancing")
        {:next_state, :awaiting_execution, data}

      _step ->
        Logger.info("[TaskOrchestrator:#{task_id}] No auto-advance, stopping")
        {:stop, :normal, data}
    end
  end

  defp handle_execution_status_changed(execution_id, status, data) do
    task_id = data.task.id

    if execution_id != data.current_execution_id do
      Logger.debug(
        "[TaskOrchestrator:#{task_id}] Ignoring status change for exec=#{execution_id} (current=#{data.current_execution_id})"
      )

      :keep_state_and_data
    else
      case status do
        "completed" ->
          Logger.info("[TaskOrchestrator:#{task_id}] Execution #{execution_id} completed")
          handle_execution_completion(data)

        "failed" ->
          Logger.error("[TaskOrchestrator:#{task_id}] Execution #{execution_id} failed")
          {:next_state, :failed, data}

        other ->
          Logger.debug("[TaskOrchestrator:#{task_id}] Ignoring execution status: #{other}")
          :keep_state_and_data
      end
    end
  end

  defp handle_execution_completion(data) do
    task_id = data.task.id

    Logger.info("[TaskOrchestrator:#{task_id}] Execution completed, -> :transitioning")

    {:next_state, :transitioning, data}
  end

  defp load_workflow_and_graph(user_id, task) do
    case Accounts.Workflows.get_by(user_id,
           conditions: [id: task.workflow_id],
           preloads: [workflow_steps: :transitions]
         ) do
      {:ok, workflow} ->
        steps = Map.new(workflow.workflow_steps, &{&1.id, &1})

        transitions =
          Map.new(workflow.workflow_steps, fn step ->
            {step.id, Enum.map(step.transitions, & &1.to_step_id)}
          end)

        {:ok, workflow, steps, transitions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reload_task(task_id) do
    case Repo.get(Task, task_id) do
      nil ->
        {:error, :task_not_found}

      task ->
        {:ok, PromptRenderer.preload_for_rendering(task)}
    end
  end

  defp get_current_step(data) do
    case data.task.current_step_id do
      nil ->
        {:error, :no_current_step}

      step_id ->
        case Map.fetch(data.steps, step_id) do
          {:ok, step} -> {:ok, step}
          :error -> {:error, :step_not_found}
        end
    end
  end

  defp get_outgoing_transitions(data, from_step_id) do
    Map.get(data.transitions, from_step_id, [])
  end

  defp select_single_transition([next_step_id]), do: {:ok, next_step_id}
  defp select_single_transition([]), do: {:error, :no_outgoing_transitions}

  defp select_single_transition(_multiple) do
    {:error, :multiple_outgoing_transitions}
  end

  defp handle_completion(data) do
    changeset = Ecto.Changeset.change(data.task, %{completed_at: DateTime.utc_now()})

    case Repo.update(changeset) do
      {:ok, updated_task} ->
        Logger.info("[TaskOrchestrator:#{data.task.id}] Set completed_at")
        {:ok, :completed, %{data | task: updated_task}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
