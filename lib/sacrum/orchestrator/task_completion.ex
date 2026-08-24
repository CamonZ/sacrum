defmodule Sacrum.Orchestrator.TaskCompletion do
  @moduledoc """
  Pure helpers for task completion and next-state determination used by the
  TaskOrchestrator FSM.
  """

  require Logger

  alias Sacrum.Orchestrator.FSMData
  alias Sacrum.Orchestrator.Routing.RouteMode
  alias Sacrum.Orchestrator.TaskRuns.{Completion, Lookup}
  alias Sacrum.Orchestrator.TaskRuns.StateTransitions
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{TaskRun, WorkflowStep}
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
  - `{:next_state, :awaiting_execution, data}` for orchestrator-owned control
    steps or when the next step has a prompt
  - `{:stop, :normal, data}` if a generic destination has no prompt
  - `{:next_state, :failed, data}` on error (nil step_id / not found)

  A finish destination is promptless and stops normally. The task has already
  been marked complete by the step-transition changeset before this decision is
  applied, so the finish step is never dispatched.
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
        next_state_for_step(step, next_step_id)
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
  def prompted_step?(%{prompt: prompt}), do: RouteMode.legacy_prompt?(prompt)

  @spec next_state_for_step(WorkflowStep.t() | struct(), binary()) ::
          {:next_state, :awaiting_execution} | {:stop, :normal, map()}
  defp next_state_for_step(step, next_step_id) do
    cond do
      step.step_type == :finish ->
        {:stop, :normal, finish_step_completed_attrs(next_step_id)}

      step.step_type == :stop ->
        {:stop, :normal, run_boundary_attrs(next_step_id)}

      step.step_type in [:wait_children, :human_input] ->
        {:next_state, :awaiting_execution}

      prompted_step?(step) ->
        {:next_state, :awaiting_execution}

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

  def maybe_mark_task_run_completed_for_decision(
        data,
        {:stop, _reason, %{outcome_kind: "run_boundary"} = attrs},
        changes
      ) do
    case Map.get(data, :task_run_id) do
      nil ->
        {:ok, changes}

      task_run_id ->
        with {:ok, task_run} <- Lookup.fetch(task_run_id),
             {:ok, task_run} <-
               task_run
               |> StateTransitions.run_boundary_changeset(attrs)
               |> Repo.update() do
          {:ok, Map.put(changes, :task_run, task_run)}
        end
    end
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

  @spec run_boundary_attrs(binary()) :: map()
  def run_boundary_attrs(step_id) do
    %{
      outcome_kind: "run_boundary",
      outcome_context: %{
        "reason" => "stop_step",
        "step_id" => step_id
      }
    }
  end

  @spec finish_step_completed_attrs(binary()) :: map()
  def finish_step_completed_attrs(step_id) do
    %{
      outcome_kind: "completed",
      outcome_context: %{
        "reason" => "finish_step",
        "current_step_id" => step_id
      }
    }
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
