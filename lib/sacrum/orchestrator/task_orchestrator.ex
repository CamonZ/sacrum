defmodule Sacrum.Orchestrator.TaskOrchestrator do
  @moduledoc """
  Gen_statem for driving a task through its entire workflow lifecycle.

  States:
  - :initializing - Load workflow graph from DB, build steps/transitions maps
  - :awaiting_execution - Request pool slot, wait for grant
  - :executing - Create StepExecution, subscribe to PubSub, wait for daemon completion
  - :evaluating - When step has eval_prompt and multiple transitions, run eval to determine which transition to take
  - :transitioning - Select next step, advance task, release pool slot
  - :completing - Handle workflow chaining or mark task complete
  - :completed - Notify scheduler, stop
  - :failed - Release pool slot, stop

  Uses handle_event_function with state_enter enabled.
  Enter callbacks handle setup/logging and schedule :state_timeout for work.
  State timeout handlers do the actual work and can transition states.
  Registered via TaskRegistry: {:via, Registry, {Sacrum.Orchestrator.TaskRegistry, task_id}}
  """

  @behaviour :gen_statem

  require Logger

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.{ExecutionDispatcher, ExecutionPool, PromptRenderer, Scheduler}
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
          current_execution_output: nil,
          eval_selected_step_id: nil,
          slot_id: nil,
          subscribed: false
        }

        Logger.info("[TaskOrchestrator:#{task_id}] Starting in :initializing state")
        {:ok, :initializing, data}
    end
  end

  # ===== ENTER CALLBACKS =====
  # Enter callbacks log the transition and schedule :state_timeout for states
  # that need to do work immediately. States that wait for external events
  # (:executing, :evaluating) do setup in enter and then wait.

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
      end

      new_data = %{data | current_execution_id: execution.id, subscribed: true}

      Logger.info(
        "[TaskOrchestrator:#{task_id}] Created execution #{execution.id}, waiting for daemon"
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

  def handle_event(:enter, prev_state, :evaluating, data) do
    task_id = data.task.id
    Logger.info("[TaskOrchestrator:#{task_id}] enter #{prev_state} -> :evaluating")

    with {:ok, current_step} <- get_current_step(data),
         {:ok, evaluation_execution} <-
           ExecutionDispatcher.create_and_dispatch_eval(
             data.user_id,
             data.task,
             current_step.id,
             data.current_execution_output
           ) do
      Logger.info(
        "[TaskOrchestrator:#{task_id}] Created eval execution #{evaluation_execution.id}, waiting for daemon"
      )

      {:keep_state, %{data | current_execution_id: evaluation_execution.id}}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{task_id}] Failed to dispatch eval execution: #{inspect(reason)}"
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

  # :fail timeout — used by :executing and :evaluating enter callbacks when setup fails
  def handle_event(:state_timeout, :fail, state, data) when state in [:executing, :evaluating] do
    Logger.error("[TaskOrchestrator:#{data.task.id}] Setup failed in #{state}, -> :failed")
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

    Logger.info(
      "[TaskOrchestrator:#{task_id}] :transitioning :run - eval_selected=#{inspect(data.eval_selected_step_id)}"
    )

    next_step_id_result =
      if data.eval_selected_step_id do
        {:ok, data.eval_selected_step_id}
      else
        with {:ok, current_step} <- get_current_step(data),
             next_transitions <- get_outgoing_transitions(data, current_step.id) do
          select_single_transition(next_transitions)
        end
      end

    with {:ok, next_step_id} <- next_step_id_result,
         {:ok, updated_task} <- TaskWorkflows.advance_to_step(data.task, next_step_id) do
      ExecutionPool.release_slot(data.slot_id)
      new_data = %{data | task: updated_task, slot_id: nil, eval_selected_step_id: nil}
      determine_next_state(next_step_id, new_data)
    else
      {:error, :no_outgoing_transitions} ->
        Logger.info("[TaskOrchestrator:#{task_id}] No outgoing transitions, treating as final")
        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :completing, %{data | slot_id: nil, eval_selected_step_id: nil}}

      {:error, reason} ->
        Logger.error("[TaskOrchestrator:#{task_id}] Error in transitioning: #{inspect(reason)}")
        ExecutionPool.release_slot(data.slot_id)
        {:next_state, :failed, %{data | slot_id: nil, eval_selected_step_id: nil}}
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
        payload: %{id: execution_id, status: status, output: output}
      } ->
        Logger.info(
          "[TaskOrchestrator:#{data.task.id}] PubSub step_execution_status_changed: exec=#{execution_id} status=#{status}"
        )

        handle_execution_status_changed(execution_id, status, output, data)

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

  def handle_event(:info, message, :evaluating, data) do
    case message do
      %Phoenix.Socket.Broadcast{
        event: "step_execution_status_changed",
        payload: %{id: execution_id, status: status, transition_result: transition_result}
      } ->
        Logger.info(
          "[TaskOrchestrator:#{data.task.id}] PubSub step_execution_status_changed in :evaluating: exec=#{execution_id} status=#{status}"
        )

        handle_eval_completion(execution_id, status, transition_result, data)

      _ ->
        Logger.debug("[TaskOrchestrator:#{data.task.id}] Ignoring message in :evaluating")
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

  defp handle_execution_status_changed(execution_id, status, output, data) do
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
          new_data = %{data | current_execution_output: output}
          handle_execution_completion(new_data)

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

    case get_current_step(data) do
      {:ok, current_step} ->
        if current_step.eval_prompt && has_multiple_transitions?(data, current_step.id) do
          Logger.info(
            "[TaskOrchestrator:#{task_id}] Step #{current_step.name} has eval_prompt, -> :evaluating"
          )

          {:next_state, :evaluating, data}
        else
          Logger.info(
            "[TaskOrchestrator:#{task_id}] Step #{current_step.name} completed, -> :transitioning"
          )

          {:next_state, :transitioning, data}
        end

      {:error, reason} ->
        Logger.warning(
          "[TaskOrchestrator:#{task_id}] Could not get current step (#{inspect(reason)}), -> :transitioning"
        )

        {:next_state, :transitioning, data}
    end
  end

  defp has_multiple_transitions?(data, step_id) do
    match?([_, _ | _], Map.get(data.transitions, step_id, []))
  end

  defp handle_eval_completion(execution_id, status, transition_result, data) do
    task_id = data.task.id

    if execution_id != data.current_execution_id do
      Logger.debug(
        "[TaskOrchestrator:#{task_id}] Ignoring eval status for exec=#{execution_id} (current=#{data.current_execution_id})"
      )

      :keep_state_and_data
    else
      case status do
        "completed" ->
          Logger.info(
            "[TaskOrchestrator:#{task_id}] Eval execution #{execution_id} completed, transition_result=#{inspect(transition_result)}"
          )

          handle_eval_transition_selection(transition_result, data)

        "failed" ->
          Logger.error("[TaskOrchestrator:#{task_id}] Eval execution #{execution_id} failed")
          {:next_state, :failed, data}

        other ->
          Logger.debug("[TaskOrchestrator:#{task_id}] Ignoring eval execution status: #{other}")
          :keep_state_and_data
      end
    end
  end

  defp handle_eval_transition_selection(transition_label, data) do
    with {:ok, current_step} <- get_current_step(data),
         {:ok, next_step_id} <-
           find_transition_by_label(current_step.transitions, transition_label) do
      Logger.info(
        "[TaskOrchestrator:#{data.task.id}] Eval selected transition: #{transition_label} -> #{next_step_id}"
      )

      new_data = %{data | current_execution_output: nil, eval_selected_step_id: next_step_id}
      {:next_state, :transitioning, new_data}
    else
      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator:#{data.task.id}] Failed to select transition: #{inspect(reason)}"
        )

        {:next_state, :failed, data}
    end
  end

  defp find_transition_by_label(transition_records, label) when is_list(transition_records) do
    case Enum.find(transition_records, &(&1.label == label)) do
      %{to_step_id: to_step_id} -> {:ok, to_step_id}
      nil -> {:error, :transition_not_found}
    end
  end

  defp find_transition_by_label(_transition_records, _label) do
    {:error, :invalid_transition_records}
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
    case Repo.get(Sacrum.Repo.Schemas.Task, task_id) do
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
    {:error, :multiple_transitions_require_eval}
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
