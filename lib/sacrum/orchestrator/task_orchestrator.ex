defmodule Sacrum.Orchestrator.TaskOrchestrator do
  @moduledoc """
  Gen_statem for driving a task through its entire workflow lifecycle.

  States:
  - :initializing - Load workflow graph from DB, build steps/transitions maps
  - :awaiting_execution - Request pool slot, wait for grant
  - :executing - Create StepExecution, subscribe to PubSub, wait for daemon completion
  - :transitioning - Select next step, advance task, release pool slot
  - :completing - Handle workflow chaining or mark task complete
  - :completed - Notify scheduler, stop
  - :failed - Release pool slot, stop

  Uses handle_event_function and state_enter callback modes.
  Registered via TaskRegistry: {:via, Registry, {Sacrum.Orchestrator.TaskRegistry, task_id}}

  Data structure:
    %{
      user_id: String.t(),
      task: Task.t(),
      project_id: String.t(),
      workflow: Workflow.t(),
      steps: %{String.t() => WorkflowStep.t()},
      transitions: %{from_step_id => [to_step_id]},
      current_execution_id: String.t() | nil,
      slot_id: integer() | nil,
      pubsub_ref: reference() | nil
    }
  """

  @behaviour :gen_statem

  require Logger
  import Ecto.Query

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, ExecutionPool, Scheduler}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas
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

  @impl :gen_statem
  def callback_mode do
    [:handle_event_function, :state_enter]
  end

  @impl :gen_statem
  def init({user_id, task_id}) do
    # Fetch task to get initial context
    case Repo.get(Sacrum.Repo.Schemas.Task, task_id) do
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
          pubsub_ref: nil
        }

        Logger.info("[TaskOrchestrator:#{task_id}] Starting in :initializing state")
        {:ok, :initializing, data}
    end
  end

  # ===== STATE: :initializing =====

  @impl :gen_statem
  def handle_event(:state_enter, _prev_state, :initializing, data) do
    task_id = data.task.id
    Logger.info("[TaskOrchestrator:#{task_id}] Entering :initializing")

    case load_workflow_and_graph(data.user_id, data.task) do
      {:ok, workflow, steps, transitions} ->
        new_data = %{
          data
          | workflow: workflow,
            steps: steps,
            transitions: transitions
        }

        Logger.info(
          "[TaskOrchestrator:#{task_id}] Workflow loaded. Transitioning to :awaiting_execution"
        )

        {:next_state, :awaiting_execution, new_data}

      {:error, reason} ->
        Logger.error("[TaskOrchestrator:#{task_id}] Failed to load workflow: #{inspect(reason)}")
        {:next_state, :failed, data}
    end
  end

  def handle_event(_, _, :initializing, _data) do
    :keep_state_and_data
  end

  # ===== STATE: :awaiting_execution =====

  @impl :gen_statem
  def handle_event(:state_enter, _prev_state, :awaiting_execution, data) do
    task_id = data.task.id

    Logger.info(
      "[TaskOrchestrator:#{task_id}] Entering :awaiting_execution, requesting pool slot"
    )

    case ExecutionPool.request_slot(self()) do
      {:ok, slot_id} ->
        Logger.info(
          "[TaskOrchestrator:#{task_id}] Got slot #{slot_id}, transitioning to :executing"
        )

        new_data = %{data | slot_id: slot_id}
        {:next_state, :executing, new_data}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to request pool slot: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  def handle_event(_, _, :awaiting_execution, _data) do
    :keep_state_and_data
  end

  # ===== STATE: :executing =====

  @impl :gen_statem
  def handle_event(:state_enter, _prev_state, :executing, data) do
    task_id = data.task.id
    Logger.info("[TaskOrchestrator:#{task_id}] Entering :executing")

    with {:ok, current_step} <- get_current_step(data),
         {:ok, execution} <-
           ExecutionDispatcher.create_and_dispatch(data.user_id, data.task, current_step.id) do
      # Subscribe to project channel for step_execution_status_changed events
      project_id = data.project_id
      topic = "project:#{project_id}"
      :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, topic)
      ref = make_ref()

      new_data = %{
        data
        | current_execution_id: execution.id,
          pubsub_ref: ref
      }

      Logger.info(
        "[TaskOrchestrator:#{task_id}] Created execution #{execution.id}, subscribed to #{topic}"
      )

      {:keep_state, new_data}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to dispatch execution: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  # Handle PubSub messages: step_execution_status_changed
  def handle_event(:info, message, :executing, data) do
    case message do
      %Phoenix.Socket.Broadcast{
        event: "step_execution_status_changed",
        payload: %{id: execution_id, status: status}
      } ->
        handle_execution_status_changed(execution_id, status, data)

      _ ->
        :keep_state_and_data
    end
  end

  def handle_event(_, _, :executing, _data) do
    :keep_state_and_data
  end

  # ===== STATE: :transitioning =====

  @impl :gen_statem
  def handle_event(:state_enter, _prev_state, :transitioning, data) do
    task_id = data.task.id
    Logger.info("[TaskOrchestrator:#{task_id}] Entering :transitioning")

    with {:ok, current_step} <- get_current_step(data),
         next_transitions <- get_outgoing_transitions(data, current_step.id),
         {:ok, next_step_id} <- select_single_transition(next_transitions),
         {:ok, updated_task} <- advance_to_next_step(data, next_step_id) do
      # Release the pool slot
      ExecutionPool.release_slot(data.slot_id)

      new_data = %{data | task: updated_task, slot_id: nil}

      # Determine next state based on step finality and auto_advance
      determine_next_state(task_id, next_step_id, data.steps, data.workflow, new_data)
    else
      {:error, :no_outgoing_transitions} ->
        # No transition defined, treat as final
        Logger.info("[TaskOrchestrator:#{task_id}] No outgoing transitions, treating as final")
        ExecutionPool.release_slot(data.slot_id)
        new_data = %{data | slot_id: nil}
        {:next_state, :completing, new_data}

      {:error, reason} ->
        Logger.error("[TaskOrchestrator:#{task_id}] Error in transitioning: #{inspect(reason)}")
        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  def handle_event(_, _, :transitioning, _data) do
    :keep_state_and_data
  end

  # ===== STATE: :completing =====

  @impl :gen_statem
  def handle_event(:state_enter, _prev_state, :completing, data) do
    task_id = data.task.id
    Logger.info("[TaskOrchestrator:#{task_id}] Entering :completing")

    case handle_completion(data) do
      {:ok, :chaining, new_data} ->
        Logger.info(
          "[TaskOrchestrator:#{task_id}] Chaining to next workflow, back to :initializing"
        )

        {:next_state, :initializing, new_data}

      {:ok, :completed, _new_data} ->
        Logger.info("[TaskOrchestrator:#{task_id}] Task completed, transitioning to :completed")
        {:next_state, :completed, data}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Error handling completion: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  def handle_event(_, _, :completing, _data) do
    :keep_state_and_data
  end

  # ===== STATE: :completed =====

  @impl :gen_statem
  def handle_event(:state_enter, _prev_state, :completed, data) do
    task_id = data.task.id
    Logger.info("[TaskOrchestrator:#{task_id}] Entering :completed")

    # Notify scheduler
    Scheduler.notify_task_completed(task_id, %{status: "completed"})

    Logger.info("[TaskOrchestrator:#{task_id}] Stopping gracefully")
    :stop
  end

  def handle_event(_, _, :completed, _data) do
    :keep_state_and_data
  end

  # ===== STATE: :failed =====

  @impl :gen_statem
  def handle_event(:state_enter, _prev_state, :failed, data) do
    task_id = data.task.id
    Logger.error("[TaskOrchestrator:#{task_id}] Entering :failed state")

    # Release slot if held
    if data.slot_id do
      ExecutionPool.release_slot(data.slot_id)
    end

    Logger.error("[TaskOrchestrator:#{task_id}] Stopping due to failure")
    :stop
  end

  def handle_event(_, _, :failed, _data) do
    :keep_state_and_data
  end

  # ===== PRIVATE HELPERS =====

  defp determine_next_state(task_id, next_step_id, steps, workflow, data) do
    # Check if step is final
    next_step = steps[next_step_id]

    if next_step.is_final do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Next step is final, transitioning to :completing"
      )

      {:next_state, :completing, data}
    else
      # Check auto_advance
      if workflow.auto_advance do
        Logger.info("[TaskOrchestrator:#{task_id}] Auto-advancing, back to :awaiting_execution")
        {:next_state, :awaiting_execution, data}
      else
        Logger.info("[TaskOrchestrator:#{task_id}] No auto-advance, stopping")
        {:stop, :normal, data}
      end
    end
  end

  defp handle_execution_status_changed(execution_id, status, data) do
    task_id = data.task.id

    if execution_id == data.current_execution_id do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Execution #{execution_id} status changed to #{status}"
      )

      case status do
        "completed" ->
          Logger.info(
            "[TaskOrchestrator:#{task_id}] Execution completed, transitioning to :transitioning"
          )

          {:next_state, :transitioning, data}

        "failed" ->
          Logger.error("[TaskOrchestrator:#{task_id}] Execution failed, transitioning to :failed")
          {:next_state, :failed, data}

        _ ->
          Logger.debug("[TaskOrchestrator:#{task_id}] Ignoring status: #{status}")
          :keep_state_and_data
      end
    else
      Logger.debug(
        "[TaskOrchestrator:#{task_id}] Ignoring event for different execution #{execution_id}"
      )

      :keep_state_and_data
    end
  end

  defp load_workflow_and_graph(user_id, task) do
    case Accounts.Workflows.get_by(user_id, conditions: [id: task.workflow_id]) do
      {:ok, workflow} ->
        workflow = Repo.preload(workflow, :workflow_steps)

        # Build steps map
        steps = Map.new(workflow.workflow_steps, &{&1.id, &1})

        # Build transitions map: %{from_step_id => [to_step_id, ...]}
        transitions = build_transitions_map(workflow.workflow_steps)

        {:ok, workflow, steps, transitions}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_transitions_map(steps) do
    step_ids = Enum.map(steps, & &1.id)

    Enum.reduce(step_ids, %{}, fn step_id, acc ->
      query =
        from(t in Sacrum.Repo.Schemas.StepTransition,
          where: t.from_step_id == ^step_id,
          select: t.to_step_id
        )

      to_step_ids = Repo.all(query)
      Map.put(acc, step_id, to_step_ids)
    end)
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

  defp select_single_transition([next_step_id]) do
    {:ok, next_step_id}
  end

  defp select_single_transition([]) do
    {:error, :no_outgoing_transitions}
  end

  defp select_single_transition(_multiple) do
    # Multiple transitions require eval — deferred to ticket 27296844
    {:error, :multiple_transitions_require_eval}
  end

  defp advance_to_next_step(data, next_step_id) do
    # Reload task to ensure fresh state
    task = Repo.get!(Schemas.Task, data.task.id)

    case TaskWorkflows.advance_to_step(task, next_step_id) do
      {:ok, updated_task} ->
        Logger.info("[TaskOrchestrator:#{task.id}] Advanced to step #{next_step_id}")
        {:ok, updated_task}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_completion(data) do
    workflow = Repo.preload(data.workflow, :on_done_workflow)

    case workflow.on_done_workflow do
      nil ->
        # Mark task as complete
        Logger.info("[TaskOrchestrator:#{data.task.id}] Setting completed_at")
        {:ok, :completed, data}

      next_workflow ->
        # Chain to next workflow
        task = Repo.get!(Schemas.Task, data.task.id)

        case TaskWorkflows.assign_workflow(task, next_workflow) do
          {:ok, updated_task} ->
            Logger.info(
              "[TaskOrchestrator:#{data.task.id}] Chained to workflow #{next_workflow.id}"
            )

            new_data = %{
              data
              | task: updated_task,
                workflow: nil,
                steps: %{},
                transitions: %{},
                current_execution_id: nil
            }

            {:ok, :chaining, new_data}

          {:error, reason} ->
            Logger.error(
              "[TaskOrchestrator:#{data.task.id}] Failed to chain workflow: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end
end
