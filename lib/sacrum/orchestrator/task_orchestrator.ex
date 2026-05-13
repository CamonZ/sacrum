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

  Uses handle_event_function with state_enter enabled. Enter callbacks schedule
  :state_timeout so timeout handlers do the real work and can transition states.
  Registered via TaskRegistry: {:via, Registry, {Sacrum.Orchestrator.TaskRegistry, task_id}}
  """

  @behaviour :gen_statem

  require Logger

  import Ecto.Query

  alias Sacrum.Orchestrator.{
    ExecutionDispatcher,
    ExecutionPool,
    FSMData,
    PromptRenderer,
    Retry,
    Scheduler,
    TaskCompletion,
    WorkflowGraph
  }

  alias Sacrum.Orchestrator.ExecutionEvents
  alias Sacrum.Orchestrator.Routing.{HumanInput, RouteStep, WaitChildren}
  alias Sacrum.Orchestrator.TaskRuns.{Completion, Failure, Lookup, Root}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task}
  alias Sacrum.Repo.TaskWorkflows

  @typep fsm_transition ::
           :keep_state_and_data
           | {:keep_state, FSMData.t()}
           | {:keep_state, FSMData.t(), list()}
           | {:next_state, atom(), FSMData.t()}
           | {:stop, atom(), FSMData.t()}

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    task_id = Keyword.fetch!(opts, :task_id)
    user_id = Keyword.fetch!(opts, :user_id)
    task_run_id = Keyword.get(opts, :task_run_id)

    :gen_statem.start_link(
      {:via, Registry, {Sacrum.Orchestrator.TaskRegistry, task_id}},
      __MODULE__,
      {user_id, task_id, task_run_id},
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
  def init({user_id, task_id, task_run_id}) do
    case Repo.get(Task, task_id) do
      nil ->
        Logger.error("[TaskOrchestrator:#{task_id}] Task not found")
        :stop

      task ->
        case ensure_task_run_id(task, task_run_id) do
          {:ok, task_run_id} ->
            data = %FSMData{
              user_id: user_id,
              task: task,
              task_run_id: task_run_id,
              project_id: task.project_id
            }

            Logger.info(
              "[TaskOrchestrator:#{task_id}] Starting user=#{user_id} project=#{task.project_id} task_run=#{task_run_id} workflow=#{inspect(task.workflow_id)} step=#{inspect(task.current_step_id)}"
            )

            {:ok, :initializing, data}

          {:error, reason} ->
            Logger.error(
              "[TaskOrchestrator:#{task_id}] Failed to initialize TaskRun: #{inspect(reason)}"
            )

            :stop
        end
    end
  end

  @impl :gen_statem
  # Catches every exit path — normal stops, crashes, and shutdowns — so a
  # supervisor-killed or exception-terminated process still leaves a trace.
  # Without this, 6304d1b9-style "process gone, no observable error" incidents
  # are impossible to diagnose from logs alone.
  def terminate(reason, state, %{task: task} = data) do
    task_id = task.id

    msg =
      "[TaskOrchestrator:#{task_id}] terminate reason=#{inspect(reason)} state=#{inspect(state)} " <>
        "current_step=#{inspect(task.current_step_id)} slot_id=#{inspect(data.slot_id)}"

    case reason do
      :normal ->
        Logger.info(msg)

      :shutdown ->
        Logger.warning(msg)

      {:shutdown, _} ->
        Logger.warning(msg)

      _ ->
        Logger.error(msg <> " current_execution=#{inspect(data.current_execution_id)}")

        mark_run_failed_if_active(data, reason, %{
          state: state,
          current_execution_id: data.current_execution_id
        })
    end

    if data.slot_id, do: ExecutionPool.release_slot(data.slot_id)
    :ok
  end

  def terminate(reason, state, _data) do
    Logger.error(
      "[TaskOrchestrator] terminate without data reason=#{inspect(reason)} state=#{inspect(state)}"
    )

    :ok
  end

  # ===== ENTER CALLBACKS =====
  # States needing work schedule a 0ms :state_timeout so work happens in the
  # timeout handler (allowing further transitions). :executing does setup in
  # enter and waits for external PubSub events.

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
         {:ok, current_step} <- WorkflowGraph.get_current_step(data) do
      data = %{data | task: task}

      case current_step.step_type do
        "wait_children" -> {:keep_state_and_data, [{:state_timeout, 0, :wait_children}]}
        "human_input" -> handle_human_input_entry(data, task, current_step)
        _ -> dispatch_execution(data, task, current_step)
      end
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
    Logger.info("[TaskOrchestrator:#{task_id}] enter #{prev_state} -> :completed, stopping")
    Scheduler.notify_task_completed(task_id, %{status: "completed"})
    {:stop, :normal, data}
  end

  def handle_event(:enter, prev_state, :failed, data) do
    Logger.error("[TaskOrchestrator:#{data.task.id}] enter #{prev_state} -> :failed, stopping")
    if data.slot_id, do: ExecutionPool.release_slot(data.slot_id)
    mark_run_failed_if_active(data, :orchestrator_failed, %{previous_state: prev_state})
    {:stop, :normal, data}
  end

  # ===== STATE TIMEOUT HANDLERS =====
  # These do the actual work and can transition states.

  # :fail timeout — used by :executing enter callbacks when setup fails
  def handle_event(:state_timeout, :fail, :executing, data) do
    {:next_state, :failed, data}
  end

  def handle_event(:state_timeout, :wait_children, :executing, data) do
    case WaitChildren.handle_wait_children_entry(data) do
      {:stop_parent, new_data} -> {:stop, :normal, new_data}
      {:advance_parent, new_data} -> {:next_state, :transitioning, new_data}
      {:error_parent, new_data} -> {:next_state, :failed, new_data}
    end
  end

  def handle_event(:state_timeout, :run, :initializing, data) do
    task_id = data.task.id

    case WorkflowGraph.load_workflow_and_graph(data.user_id, data.task) do
      {:ok, workflow, steps, transitions} ->
        Logger.info(
          "[TaskOrchestrator:#{task_id}] Loaded workflow #{workflow.id} with #{map_size(steps)} steps"
        )

        {:next_state, :awaiting_execution,
         %{data | workflow: workflow, steps: steps, transitions: transitions}}

      {:error, reason} ->
        Logger.error("[TaskOrchestrator:#{task_id}] Failed to load workflow: #{inspect(reason)}")
        {:next_state, :failed, data}
    end
  end

  def handle_event(:state_timeout, :run, :awaiting_execution, data) do
    task_id = data.task.id

    case resume_reason(data) do
      :wait_children ->
        Logger.info(
          "[TaskOrchestrator:#{task_id}] Resuming from wait_children, transitioning directly"
        )

        {:next_state, :transitioning, data}

      :human_input_completed ->
        Logger.info(
          "[TaskOrchestrator:#{task_id}] Resuming from human_input, transitioning directly"
        )

        {:next_state, :transitioning, data}

      :human_input_waiting ->
        Logger.info("[TaskOrchestrator:#{task_id}] human_input is still waiting, stopping")
        {:stop, :normal, data}

      :fresh ->
        request_execution_slot(task_id, data)
    end
  end

  def handle_event(:state_timeout, :run, :transitioning, data) do
    task_id = data.task.id

    case WorkflowGraph.get_current_step(data) do
      {:ok, %{step_type: "route"} = current_step} ->
        RouteStep.handle_route_step_transition(data, current_step)

      {:ok, %{step_type: type} = current_step}
      when type in ["execute", "evaluate", "human_input"] ->
        handle_single_transition_step(data, current_step)

      {:ok, %{step_type: "wait_children"} = current_step} ->
        handle_wait_children_transition(data, current_step)

      {:ok, %{step_type: other}} ->
        Logger.error("[TaskOrchestrator:#{task_id}] Unknown step type: #{other}")
        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil}}

      {:error, reason} ->
        Logger.error("[TaskOrchestrator:#{task_id}] Error in :transitioning: #{inspect(reason)}")
        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  def handle_event(:state_timeout, :run, :completing, data) do
    task_id = data.task.id

    case TaskCompletion.handle_completion(data) do
      {:ok, :completed, new_data} ->
        {:next_state, :completed, new_data}

      {:error, reason} ->
        Logger.error("[TaskOrchestrator:#{task_id}] Completion failed: #{inspect(reason)}")
        {:next_state, :failed, data}
    end
  end

  # ===== INFO HANDLERS (PubSub) =====

  def handle_event(
        :info,
        %Phoenix.Socket.Broadcast{
          event: "step_execution_status_changed",
          payload: %{id: execution_id, status: status}
        },
        :executing,
        data
      ) do
    handle_execution_status_changed(execution_id, status, data)
  end

  def handle_event(
        :info,
        {:step_execution_status_changed, %{id: execution_id, status: status}},
        :executing,
        data
      ) do
    handle_execution_status_changed(execution_id, status, data)
  end

  def handle_event(:info, _message, :executing, _data), do: :keep_state_and_data

  # Catch-all for unhandled events in any state
  def handle_event(event_type, event_content, state, data) do
    Logger.warning(
      "[TaskOrchestrator:#{data.task.id}] Unhandled event type=#{inspect(event_type)} content=#{inspect(event_content)} state=#{inspect(state)}"
    )

    :keep_state_and_data
  end

  # ===== TRANSITION HANDLERS =====

  @spec handle_wait_children_transition(FSMData.t(), struct()) :: fsm_transition()
  defp handle_wait_children_transition(data, current_step) do
    task_id = data.task.id
    next_transitions = WorkflowGraph.get_outgoing_transitions(data, current_step.id)

    with {:ok, next_step_id} <- WorkflowGraph.select_single_transition(next_transitions),
         {:ok, %{task: updated_task}} <-
           commit_wait_children_transition(data, next_step_id) do
      ExecutionPool.release_slot(data.slot_id)

      TaskCompletion.determine_next_state(next_step_id, %{
        data
        | task: updated_task,
          slot_id: nil
      })
    else
      {:error, :no_outgoing_transitions} ->
        Logger.info(
          "[TaskOrchestrator:#{task_id}] No outgoing transitions from wait_children, treating as final"
        )

        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :completing, %{data | slot_id: nil}}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Error in wait_children transition: #{inspect(reason)}"
        )

        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  @spec handle_human_input_entry(FSMData.t(), Task.t(), struct()) :: fsm_transition()
  defp handle_human_input_entry(data, task, current_step) do
    case HumanInput.handle_entry(data, task, current_step) do
      {:parked, new_data} -> {:stop, :normal, new_data}
      {:error, new_data} -> {:next_state, :failed, new_data}
    end
  end

  @spec handle_single_transition_step(FSMData.t(), struct()) :: fsm_transition()
  defp handle_single_transition_step(data, current_step) do
    task_id = data.task.id
    next_transitions = WorkflowGraph.get_outgoing_transitions(data, current_step.id)

    with {:ok, next_step_id} <- WorkflowGraph.select_single_transition(next_transitions),
         {:ok, %{task: updated_task}} <- commit_task_step_transition(data, next_step_id) do
      ExecutionPool.release_slot(data.slot_id)

      TaskCompletion.determine_next_state(next_step_id, %{
        data
        | task: updated_task,
          slot_id: nil
      })
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

  @spec commit_wait_children_transition(FSMData.t(), binary()) :: {:ok, map()} | {:error, term()}
  defp commit_wait_children_transition(data, next_step_id) do
    decision = TaskCompletion.next_state_decision(next_step_id, data)

    Repo.transaction(fn ->
      with {:ok, changes} <- maybe_complete_waiting_execution(data.task.id, %{}),
           {:ok, changes} <- advance_task_step(data, next_step_id, changes),
           {:ok, changes} <- maybe_mark_task_run_completed(data, decision, changes) do
        changes
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec commit_task_step_transition(FSMData.t(), binary()) :: {:ok, map()} | {:error, term()}
  defp commit_task_step_transition(data, next_step_id) do
    decision = TaskCompletion.next_state_decision(next_step_id, data)

    Repo.transaction(fn ->
      with {:ok, changes} <- advance_task_step(data, next_step_id, %{}),
           {:ok, changes} <- maybe_mark_task_run_completed(data, decision, changes) do
        changes
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec maybe_complete_waiting_execution(binary(), map()) :: {:ok, map()} | {:error, term()}
  defp maybe_complete_waiting_execution(task_id, changes) do
    case latest_waiting_execution(task_id) do
      nil ->
        {:ok, changes}

      execution ->
        execution
        |> StepExecution.update_changeset(%{status: "completed"})
        |> Repo.update()
        |> put_transaction_change(changes, :waiting_execution)
    end
  end

  @spec advance_task_step(FSMData.t(), binary(), map()) :: {:ok, map()} | {:error, term()}
  defp advance_task_step(data, next_step_id, changes) do
    with {:ok, changeset} <-
           TaskWorkflows.advance_to_step_changeset(data.task, next_step_id,
             skip_orchestrator_check: true
           ),
         {:ok, task} <- Repo.update(changeset) do
      {:ok, Map.put(changes, :task, task)}
    end
  end

  @spec maybe_mark_task_run_completed(FSMData.t(), tuple(), map()) ::
          {:ok, map()} | {:error, term()}
  defp maybe_mark_task_run_completed(_data, {:next_state, _state}, changes), do: {:ok, changes}
  defp maybe_mark_task_run_completed(_data, {:failed, _reason}, changes), do: {:ok, changes}

  defp maybe_mark_task_run_completed(data, {:stop, _reason, attrs}, changes) do
    case Map.get(data, :task_run_id) do
      nil ->
        {:ok, changes}

      task_run_id ->
        mark_task_run_completed(task_run_id, attrs, changes)
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

  @spec put_transaction_change({:ok, term()} | {:error, term()}, map(), atom()) ::
          {:ok, map()} | {:error, term()}
  defp put_transaction_change({:ok, value}, changes, key), do: {:ok, Map.put(changes, key, value)}
  defp put_transaction_change({:error, reason}, _changes, _key), do: {:error, reason}

  # ===== PRIVATE HELPERS =====

  @spec ensure_task_run_id(Task.t(), binary() | nil) :: {:ok, binary()} | {:error, term()}
  defp ensure_task_run_id(_task, task_run_id) when is_binary(task_run_id), do: {:ok, task_run_id}

  defp ensure_task_run_id(task, nil) do
    with {:ok, task_run} <- Root.get_or_create(task) do
      {:ok, task_run.id}
    end
  end

  @spec mark_run_failed_if_active(map(), term(), map()) :: :ok
  defp mark_run_failed_if_active(%{task_run_id: nil}, _reason, _context), do: :ok

  defp mark_run_failed_if_active(%{task_run_id: task_run_id} = data, reason, context) do
    context =
      Map.merge(
        %{
          task_id: data.task.id,
          current_execution_id: data.current_execution_id,
          run_retry_attempt: data.run_retry_attempt
        },
        context
      )

    case Failure.mark_if_active(task_run_id, reason, context) do
      {:ok, _task_run_or_terminal} ->
        :ok

      {:error, reason} ->
        Logger.error("[TaskOrchestrator] Failed to mark TaskRun failed: #{inspect(reason)}")
        :ok
    end
  end

  @spec handle_execution_status_changed(binary(), String.t(), FSMData.t()) :: fsm_transition()
  defp handle_execution_status_changed(execution_id, _status, %{current_execution_id: current})
       when execution_id != current,
       do: :keep_state_and_data

  defp handle_execution_status_changed(execution_id, "completed", data) do
    {:ok, step} = WorkflowGraph.get_current_step(data)

    Logger.info(
      "[TaskOrchestrator:#{data.task.id}] Execution #{execution_id} completed step_type=#{step.step_type}"
    )

    {:next_state, :transitioning, %{data | run_retry_attempt: 0}}
  end

  defp handle_execution_status_changed(execution_id, "failed", data) do
    Retry.handle_execution_failure(execution_id, data)
  end

  defp handle_execution_status_changed(_execution_id, _status, _data), do: :keep_state_and_data

  @spec reload_task(binary()) :: {:ok, Task.t()} | {:error, :task_not_found}
  defp reload_task(task_id) do
    case Repo.get(Task, task_id) do
      nil -> {:error, :task_not_found}
      task -> {:ok, PromptRenderer.preload_for_rendering(task)}
    end
  end

  @spec dispatch_execution(FSMData.t(), Task.t(), struct()) :: fsm_transition()
  defp dispatch_execution(data, task, current_step) do
    task_id = data.task.id

    case ExecutionDispatcher.create_and_dispatch(
           data.user_id,
           task,
           current_step.id,
           data.task_run_id,
           data.pending_handoff
         ) do
      {:ok, execution} ->
        :ok = ExecutionEvents.subscribe(execution.id)

        Logger.info(
          "[TaskOrchestrator:#{task_id}] Dispatched execution #{execution.id} step=#{current_step.name}"
        )

        {:keep_state, %{data | current_execution_id: execution.id, pending_handoff: nil}}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to dispatch execution: #{inspect(reason)}"
        )

        {:keep_state, data, [{:state_timeout, 0, :fail}]}
    end
  end

  @spec request_execution_slot(binary(), FSMData.t()) ::
          {:next_state, :executing | :failed, FSMData.t()}
  defp request_execution_slot(task_id, data) do
    case ExecutionPool.request_slot(self()) do
      {:ok, slot_id} ->
        Logger.info("[TaskOrchestrator:#{task_id}] Got pool slot #{slot_id}")
        {:next_state, :executing, %{data | slot_id: slot_id}}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to request pool slot: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  @spec resume_reason(FSMData.t()) ::
          :wait_children | :human_input_completed | :human_input_waiting | :fresh
  defp resume_reason(data) do
    case WorkflowGraph.get_current_step(data) do
      {:ok, %{step_type: "wait_children"}} ->
        if latest_waiting_execution(data.task.id), do: :wait_children, else: :fresh

      {:ok, %{step_type: "human_input"}} ->
        case human_input_latest_execution_status(data) do
          "completed" -> :human_input_completed
          "waiting" -> :human_input_waiting
          _ -> :fresh
        end

      _ ->
        :fresh
    end
  end

  @spec human_input_latest_execution_status(FSMData.t()) :: String.t() | nil
  defp human_input_latest_execution_status(data) do
    with {:ok, task_run} <- Lookup.fetch(data.task_run_id),
         execution_id when is_binary(execution_id) <- task_run.latest_step_execution_id,
         %StepExecution{status: status, step_id: step_id} <-
           Repo.get(StepExecution, execution_id) do
      if step_id == data.task.current_step_id, do: status
    else
      _ -> nil
    end
  end

  @spec latest_waiting_execution(binary()) :: StepExecution.t() | nil
  defp latest_waiting_execution(task_id) do
    Repo.one(
      from(e in StepExecution,
        where: e.task_id == ^task_id and e.status == "waiting",
        order_by: [desc: e.inserted_at],
        limit: 1
      )
    )
  end
end
