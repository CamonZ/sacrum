defmodule Sacrum.Orchestrator.TaskCompletion do
  @moduledoc """
  Pure helpers for task completion and next-state determination used by the
  TaskOrchestrator FSM.
  """

  require Logger

  alias Sacrum.Orchestrator.{FSMData, TaskRunLifecycle}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Tasks.Status

  @doc """
  Mark the task as completed by setting `completed_at` (idempotent — only stamps
  when currently nil) and refresh `status` in a single update.

  Returns `{:ok, :completed, new_data}` or `{:error, changeset}`.
  """
  @spec handle_completion(FSMData.t()) ::
          {:ok, :completed, FSMData.t()} | {:error, Ecto.Changeset.t()}
  def handle_completion(%{task: %{completed_at: nil} = task} = data) do
    task
    |> Ecto.Changeset.change(%{completed_at: DateTime.utc_now()})
    |> Status.put_status()
    |> Repo.update()
    |> case do
      {:ok, refreshed} ->
        mark_task_run_completed(data)
        Broadcaster.broadcast({:ok, refreshed}, :task_updated, :project)
        {:ok, :completed, %{data | task: refreshed}}

      {:error, _changeset} = error ->
        error
    end
  end

  def handle_completion(data) do
    mark_task_run_completed(data)
    {:ok, :completed, data}
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
    case data.steps[next_step_id] do
      nil ->
        Logger.error("[TaskOrchestrator:#{data.task.id}] Step #{next_step_id} not found in cache")

        {:next_state, :failed, data}

      %{is_final: true} ->
        {:next_state, :completing, data}

      _step ->
        if data.workflow.auto_advance do
          {:next_state, :awaiting_execution, data}
        else
          mark_task_run_completed(data, %{
            outcome_kind: "step_completed",
            outcome_context: %{
              "reason" => "auto_advance_disabled",
              "current_step_id" => next_step_id
            }
          })

          {:stop, :normal, data}
        end
    end
  end

  defp mark_task_run_completed(data, attrs \\ %{outcome_kind: "completed"}) do
    case Map.get(data, :task_run_id) do
      nil ->
        :ok

      task_run_id ->
        case TaskRunLifecycle.mark_completed(task_run_id, attrs) do
          {:ok, _task_run} ->
            :ok

          {:error, reason} ->
            Logger.error("[TaskCompletion] Failed to mark TaskRun completed: #{inspect(reason)}")
            :ok
        end
    end
  end
end
