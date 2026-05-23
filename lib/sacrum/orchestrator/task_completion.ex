defmodule Sacrum.Orchestrator.TaskCompletion do
  @moduledoc """
  Pure helpers for task completion and next-state determination used by the
  TaskOrchestrator FSM.
  """

  require Logger

  alias Sacrum.Orchestrator.FSMData
  alias Sacrum.Orchestrator.TaskRuns.{Completion, Lookup}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{TaskRun, Workflow, WorkflowStep}
  alias Sacrum.Tasks.Status

  @doc """
  Mark the task as completed by setting `completed_at` (idempotent — only stamps
  when currently nil) and refresh `status` in a single update.

  Returns `{:ok, :completed, new_data}` or `{:error, changeset}`.
  """
  @spec handle_completion(FSMData.t()) ::
          {:ok, :completed, FSMData.t()} | {:error, term()}
  def handle_completion(%FSMData{} = data) do
    case commit_completion(data) do
      {:ok, %{task: refreshed}} ->
        {:ok, :completed, %{data | task: refreshed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec commit_completion(FSMData.t()) :: {:ok, map()} | {:error, term()}
  defp commit_completion(%FSMData{task: task, task_run_id: task_run_id}) do
    Repo.transaction(fn ->
      with {:ok, task_run} <- fetch_optional_task_run(task_run_id),
           {:ok, refreshed} <- Repo.update(completion_changeset(task)),
           {:ok, changes} <-
             maybe_mark_task_run_completed(task_run, %{outcome_kind: "completed"}, %{
               task: refreshed
             }) do
        changes
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Determine the next FSM state based on the destination step configuration.

  Returns gen_statem tuples:
  - `{:next_state, :awaiting_execution, data}` if the next step has a prompt
  - `{:stop, :normal, data}` if the next step has no prompt
  - `{:next_state, :failed, data}` on error (nil step_id / not found)

  `:completing` is reached only after the executed step's StepExecution reports
  completed and the orchestrator finds no outgoing transitions; it is not a
  shortcut for final steps at this decision point.
  """
  @spec determine_next_state(binary() | nil, FSMData.t()) ::
          {:next_state, atom(), FSMData.t()} | {:stop, atom(), FSMData.t()}
  def determine_next_state(nil, data) do
    Logger.error("[TaskOrchestrator:#{data.task.id}] No current step after transition")
    {:next_state, :failed, data}
  end

  def determine_next_state(next_step_id, data) do
    next_step_id
    |> next_state_decision(data)
    |> to_fsm_transition(data)
  end

  @spec next_state_decision(binary() | nil, FSMData.t()) ::
          {:next_state, :awaiting_execution}
          | {:stop, :normal, map()}
          | {:failed, term()}
  def next_state_decision(nil, _data), do: {:failed, :no_current_step}

  def next_state_decision(next_step_id, data) do
    case data.steps[next_step_id] do
      nil ->
        {:failed, {:step_not_found, next_step_id}}

      step ->
        next_state_for_step(data.workflow, step, next_step_id)
    end
  end

  @spec promptless_step_completed_attrs(binary()) :: map()
  def promptless_step_completed_attrs(next_step_id) do
    %{
      outcome_kind: "step_completed",
      outcome_context: %{
        "reason" => "promptless_destination_step",
        "current_step_id" => next_step_id
      }
    }
  end

  @spec prompted_step?(WorkflowStep.t() | struct()) :: boolean()
  def prompted_step?(%{prompt: prompt}) when is_binary(prompt), do: String.trim(prompt) != ""
  def prompted_step?(_step), do: false

  @spec next_state_for_step(Workflow.t() | struct(), WorkflowStep.t() | struct(), binary()) ::
          {:next_state, :awaiting_execution | :completing} | {:stop, :normal, map()}
  defp next_state_for_step(workflow, step, next_step_id) do
    cond do
      prompted_step?(step) ->
        {:next_state, :awaiting_execution}

      terminal_route_destination?(workflow, step) ->
        {:next_state, :completing}

      true ->
        {:stop, :normal, promptless_step_completed_attrs(next_step_id)}
    end
  end

  @spec maybe_mark_task_run_completed_for_decision(FSMData.t() | map(), tuple(), map()) ::
          {:ok, map()} | {:error, term()}
  def maybe_mark_task_run_completed_for_decision(_data, {:next_state, _state}, changes) do
    {:ok, changes}
  end

  def maybe_mark_task_run_completed_for_decision(_data, {:failed, _reason}, changes) do
    {:ok, changes}
  end

  def maybe_mark_task_run_completed_for_decision(data, {:stop, _reason, attrs}, changes) do
    case Map.get(data, :task_run_id) do
      nil ->
        {:ok, changes}

      task_run_id ->
        with {:ok, task_run} <- Lookup.fetch(task_run_id) do
          maybe_mark_task_run_completed(task_run, attrs, changes)
        end
    end
  end

  @doc """
  Returns true when a route destination is the final step of a final workflow.
  """
  @spec terminal_route_destination?(Workflow.t() | struct(), WorkflowStep.t()) :: boolean()
  def terminal_route_destination?(%{is_final: true}, %WorkflowStep{is_final: true}), do: true
  def terminal_route_destination?(_workflow, _step), do: false

  @doc """
  Stop decision attrs for terminal route completion.
  """
  @spec terminal_route_completed_attrs(binary()) :: map()
  def terminal_route_completed_attrs(step_id) do
    %{
      outcome_kind: "completed",
      outcome_context: %{
        "reason" => "terminal_route",
        "current_step_id" => step_id
      }
    }
  end

  @doc """
  Marks a routed terminal destination as a completed task and active run.

  Call this inside the caller's route transaction after the route decision and
  task movement have been persisted.
  """
  @spec complete_terminal_route(TaskRun.t() | nil, struct(), map()) ::
          {:ok, map()} | {:error, term()}
  def complete_terminal_route(task_run, task, changes) do
    with {:ok, refreshed} <- Repo.update(completion_changeset(task)) do
      maybe_mark_task_run_completed(
        task_run,
        terminal_route_completed_attrs(refreshed.current_step_id),
        %{
          changes
          | task: refreshed
        }
      )
    end
  end

  @spec completion_changeset(struct()) :: Ecto.Changeset.t()
  def completion_changeset(%{completed_at: nil} = task) do
    task
    |> Ecto.Changeset.change(%{completed_at: DateTime.utc_now()})
    |> Status.put_status()
  end

  def completion_changeset(task) do
    task
    |> Ecto.Changeset.change()
    |> Status.put_status()
  end

  @spec to_fsm_transition(tuple(), FSMData.t()) ::
          {:next_state, atom(), FSMData.t()} | {:stop, atom(), FSMData.t()}
  defp to_fsm_transition({:failed, :no_current_step}, data) do
    Logger.error("[TaskOrchestrator:#{data.task.id}] No current step after transition")
    {:next_state, :failed, data}
  end

  defp to_fsm_transition({:failed, {:step_not_found, step_id}}, data) do
    Logger.error("[TaskOrchestrator:#{data.task.id}] Step #{step_id} not found in cache")
    {:next_state, :failed, data}
  end

  defp to_fsm_transition({:next_state, state}, data), do: {:next_state, state, data}
  defp to_fsm_transition({:stop, reason, _attrs}, data), do: {:stop, reason, data}

  @spec fetch_optional_task_run(binary() | nil) :: {:ok, TaskRun.t() | nil} | {:error, term()}
  defp fetch_optional_task_run(nil), do: {:ok, nil}

  defp fetch_optional_task_run(task_run_id) do
    case Lookup.fetch(task_run_id) do
      {:ok, %TaskRun{} = task_run} -> {:ok, task_run}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec maybe_mark_task_run_completed(TaskRun.t() | nil, map(), map()) ::
          {:ok, map()} | {:error, term()}
  defp maybe_mark_task_run_completed(nil, _attrs, changes), do: {:ok, changes}

  defp maybe_mark_task_run_completed(%TaskRun{} = task_run, attrs, changes) do
    task_run
    |> Completion.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, task_run} ->
        {:ok, Map.put(changes, :task_run, task_run)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
