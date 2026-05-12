defmodule Sacrum.Orchestrator.TaskCompletion do
  @moduledoc """
  Pure helpers for task completion and next-state determination used by the
  TaskOrchestrator FSM.
  """

  require Logger

  alias Sacrum.Orchestrator.FSMData
  alias Sacrum.Orchestrator.TaskRuns.{Completion, Lookup}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.{Task, TaskRun}
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
      {:ok, %{task: refreshed} = changes} ->
        Broadcaster.broadcast({:ok, refreshed}, :task_updated, :project)
        broadcast_run_end_step_changed(data, refreshed, changes)
        {:ok, :completed, %{data | task: refreshed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec broadcast_run_end_step_changed(FSMData.t(), Task.t(), map()) :: :ok
  defp broadcast_run_end_step_changed(%FSMData{task_run_id: nil}, _task, _changes), do: :ok

  defp broadcast_run_end_step_changed(%FSMData{task_run_id: task_run_id}, task, changes) do
    case Lookup.from_changes_or_fetch(task_run_id, changes) do
      %TaskRun{} = task_run ->
        Broadcaster.broadcast_task_run_step_changed(task_run, task, task.current_step_id, nil)

      _ ->
        :ok
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
  Determine the next FSM state based on the step and workflow configuration.

  Returns gen_statem tuples:
  - `{:next_state, :completing, data}` if the step is final
  - `{:next_state, :awaiting_execution, data}` if auto-advance is enabled
  - `{:stop, :normal, data}` if no auto-advance
  - `{:next_state, :failed, data}` on error (nil step_id / not found)
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
          {:next_state, :completing | :awaiting_execution}
          | {:stop, :normal, map()}
          | {:failed, term()}
  def next_state_decision(nil, _data), do: {:failed, :no_current_step}

  def next_state_decision(next_step_id, data) do
    case data.steps[next_step_id] do
      nil ->
        {:failed, {:step_not_found, next_step_id}}

      %{is_final: true} ->
        {:next_state, :completing}

      _step ->
        if data.workflow.auto_advance do
          {:next_state, :awaiting_execution}
        else
          {:stop, :normal, step_completed_attrs(next_step_id)}
        end
    end
  end

  @spec step_completed_attrs(binary()) :: map()
  def step_completed_attrs(next_step_id) do
    %{
      outcome_kind: "step_completed",
      outcome_context: %{
        "reason" => "auto_advance_disabled",
        "current_step_id" => next_step_id
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
        Broadcaster.broadcast_task_run({:ok, task_run}, :task_run_updated)
        {:ok, Map.put(changes, :task_run, task_run)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
