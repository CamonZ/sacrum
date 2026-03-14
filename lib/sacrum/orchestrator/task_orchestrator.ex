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
  """

  @behaviour :gen_statem

  require Logger

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, ExecutionPool, Scheduler}
  alias Sacrum.Repo
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
          subscribed: false
        }

        Logger.info("[TaskOrchestrator:#{task_id}] Starting in :initializing state")
        {:ok, :initializing, data}
    end
  end

  # ===== STATE: :initializing =====

  @impl :gen_statem
  def handle_event(:state_enter, _prev_state, :initializing, data) do
    task_id = data.task.id

    case load_workflow_and_graph(data.user_id, data.task) do
      {:ok, workflow, steps, transitions} ->
        new_data = %{
          data
          | workflow: workflow,
            steps: steps,
            transitions: transitions
        }

        {:next_state, :awaiting_execution, new_data}

      {:error, reason} ->
        Logger.error("[TaskOrchestrator:#{task_id}] Failed to load workflow: #{inspect(reason)}")
        {:next_state, :failed, data}
    end
  end

  # ===== STATE: :awaiting_execution =====

  def handle_event(:state_enter, _prev_state, :awaiting_execution, data) do
    task_id = data.task.id

    case ExecutionPool.request_slot(self()) do
      {:ok, slot_id} ->
        {:next_state, :executing, %{data | slot_id: slot_id}}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to request pool slot: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  # ===== STATE: :executing =====

  def handle_event(:state_enter, _prev_state, :executing, data) do
    task_id = data.task.id

    with {:ok, current_step} <- get_current_step(data),
         {:ok, execution} <-
           ExecutionDispatcher.create_and_dispatch(data.user_id, data.task, current_step.id) do
      # Subscribe to PubSub only once (avoid duplicate subscriptions on re-entry)
      unless data.subscribed do
        :ok = Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{data.project_id}")
      end

      new_data = %{data | current_execution_id: execution.id, subscribed: true}

      Logger.info("[TaskOrchestrator:#{task_id}] Created execution #{execution.id}")
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

  # ===== STATE: :transitioning =====

  def handle_event(:state_enter, _prev_state, :transitioning, data) do
    task_id = data.task.id

    with {:ok, current_step} <- get_current_step(data),
         next_transitions <- get_outgoing_transitions(data, current_step.id),
         {:ok, next_step_id} <- select_single_transition(next_transitions),
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
        Logger.error("[TaskOrchestrator:#{task_id}] Error in transitioning: #{inspect(reason)}")
        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil}}
    end
  end

  # ===== STATE: :completing =====

  def handle_event(:state_enter, _prev_state, :completing, data) do
    task_id = data.task.id

    case handle_completion(data) do
      {:ok, :chaining, new_data} ->
        Logger.info("[TaskOrchestrator:#{task_id}] Chaining to next workflow")
        {:next_state, :initializing, new_data}

      {:ok, :completed, new_data} ->
        {:next_state, :completed, new_data}

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Error handling completion: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  # ===== STATE: :completed =====

  def handle_event(:state_enter, _prev_state, :completed, data) do
    task_id = data.task.id
    Scheduler.notify_task_completed(task_id, %{status: "completed"})
    Logger.info("[TaskOrchestrator:#{task_id}] Completed, stopping")
    {:stop, :normal, data}
  end

  # ===== STATE: :failed =====

  def handle_event(:state_enter, _prev_state, :failed, data) do
    task_id = data.task.id

    if data.slot_id do
      ExecutionPool.release_slot(data.slot_id)
    end

    Logger.error("[TaskOrchestrator:#{task_id}] Failed, stopping")
    {:stop, :normal, data}
  end

  # Catch-all for unhandled events in any state
  def handle_event(_, _, _, _data) do
    :keep_state_and_data
  end

  # ===== PRIVATE HELPERS =====

  defp determine_next_state(next_step_id, data) do
    next_step = data.steps[next_step_id]
    task_id = data.task.id

    cond do
      next_step.is_final ->
        Logger.info("[TaskOrchestrator:#{task_id}] Next step is final")
        {:next_state, :completing, data}

      data.workflow.auto_advance ->
        Logger.info("[TaskOrchestrator:#{task_id}] Auto-advancing")
        {:next_state, :awaiting_execution, data}

      true ->
        Logger.info("[TaskOrchestrator:#{task_id}] No auto-advance, stopping")
        {:stop, :normal, data}
    end
  end

  defp handle_execution_status_changed(execution_id, status, data) do
    if execution_id != data.current_execution_id do
      :keep_state_and_data
    else
      case status do
        "completed" ->
          {:next_state, :transitioning, data}

        "failed" ->
          Logger.error("[TaskOrchestrator:#{data.task.id}] Execution failed")
          {:next_state, :failed, data}

        _ ->
          :keep_state_and_data
      end
    end
  end

  defp load_workflow_and_graph(user_id, task) do
    case Accounts.Workflows.get_by(user_id,
           conditions: [id: task.workflow_id],
           preloads: [:on_done_workflow, workflow_steps: :transitions]
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
    # Multiple transitions require eval — deferred to ticket 27296844
    {:error, :multiple_transitions_require_eval}
  end

  defp handle_completion(data) do
    case data.workflow.on_done_workflow do
      nil ->
        # Actually set completed_at on the task
        changeset = Ecto.Changeset.change(data.task, %{completed_at: DateTime.utc_now()})

        case Repo.update(changeset) do
          {:ok, updated_task} ->
            Logger.info("[TaskOrchestrator:#{data.task.id}] Set completed_at")
            {:ok, :completed, %{data | task: updated_task}}

          {:error, reason} ->
            {:error, reason}
        end

      next_workflow ->
        case TaskWorkflows.assign_workflow(data.task, next_workflow) do
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
            {:error, reason}
        end
    end
  end
end
