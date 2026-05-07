defmodule Sacrum.TaskRuns.RunControls do
  @moduledoc """
  Presenter for GUI Run/Stop controls derived from server-owned TaskRun state.
  """

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.TaskRegistry
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepExecution, Task, TaskRun}
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @type controls :: %{
          runnable: boolean(),
          stoppable: boolean(),
          disabled_reason_code: String.t() | nil,
          disabled_reason: String.t() | nil,
          active_run: TaskRun.t() | nil
        }

  @reason_messages %{
    "active_run" => "Task already has an active run",
    "archived" => "Task is archived",
    "blocked" => "Task has incomplete blockers",
    "completed" => "Task is already completed",
    "missing_workflow" => "Task has no workflow assigned",
    "orchestrator_active" => "Task has an active orchestrator",
    "stale_active_run" =>
      "Task run appears active, but no orchestrator is available to stop its in-flight work",
    "stopping" => "Task run is already stopping"
  }

  @in_flight_execution_statuses ["started", "in_progress", "waiting"]
  @control_fields [:runnable, :stoppable, :disabled_reason_code, :disabled_reason, :active_run]

  @spec for_task(String.t(), String.t() | Task.t()) :: {:ok, controls()} | {:error, :not_found}
  def for_task(user_id, task_id) when is_binary(user_id) and is_binary(task_id) do
    with {:ok, %Task{} = task} <- Accounts.Tasks.find(user_id, task_id) do
      for_task(user_id, task)
    end
  end

  def for_task(user_id, %Task{} = task) when is_binary(user_id) do
    {:ok, Map.fetch!(for_tasks(user_id, [task]), task.id)}
  end

  @spec for_tasks(String.t(), [Task.t()]) :: %{String.t() => controls()}
  def for_tasks(user_id, tasks) when is_binary(user_id) and is_list(tasks) do
    task_ids = tasks |> Enum.map(& &1.id) |> Enum.uniq()
    active_runs_by_task_id = active_runs_by_task_id(user_id, task_ids)

    blocked_task_ids =
      task_ids |> TaskDependencies.incomplete_direct_blocker_task_ids() |> MapSet.new()

    Map.new(tasks, fn task ->
      controls =
        present(task, Map.get(active_runs_by_task_id, task.id),
          blocked?: MapSet.member?(blocked_task_ids, task.id),
          orchestrator_running?: orchestrator_running?(task.id)
        )

      {task.id, controls}
    end)
  end

  @spec for_task_run(TaskRun.t()) :: {:ok, controls()} | {:error, :not_found}
  def for_task_run(%TaskRun{user_id: user_id, task_id: task_id} = task_run)
      when is_binary(user_id) and is_binary(task_id) do
    with {:ok, %Task{} = task} <- Accounts.Tasks.find(user_id, task_id) do
      {:ok, present(task, active_run_or_nil(task_run))}
    end
  end

  @spec present(Task.t(), TaskRun.t() | nil, keyword()) :: controls()
  def present(task, active_run, opts \\ [])

  def present(%Task{} = task, %TaskRun{} = active_run, opts) do
    if active_status?(active_run.status) do
      active_controls(task, active_run, opts)
    else
      present(task, nil, opts)
    end
  end

  def present(%Task{} = task, nil, opts) do
    cond do
      task.archived ->
        disabled("archived")

      task_completed?(task) ->
        disabled("completed")

      missing_workflow?(task) ->
        disabled("missing_workflow")

      blocked?(task, opts) ->
        disabled("blocked")

      orchestrator_running?(task.id, opts) ->
        disabled("orchestrator_active")

      true ->
        %{
          runnable: true,
          stoppable: false,
          disabled_reason_code: nil,
          disabled_reason: nil,
          active_run: nil
        }
    end
  end

  @spec to_payload(controls()) :: map()
  def to_payload(controls), do: Map.take(controls, @control_fields)

  defp active_controls(task, active_run, opts) do
    cond do
      stale_active_run?(task, active_run, opts) ->
        disabled("stale_active_run", active_run)

      not TaskRunStatus.stoppable?(normalize_status(active_run.status)) ->
        disabled("stopping", active_run)

      true ->
        %{
          runnable: false,
          stoppable: true,
          disabled_reason_code: "active_run",
          disabled_reason: Map.fetch!(@reason_messages, "active_run"),
          active_run: active_run
        }
    end
  end

  defp disabled(reason_code, active_run \\ nil) do
    %{
      runnable: false,
      stoppable: false,
      disabled_reason_code: reason_code,
      disabled_reason: Map.fetch!(@reason_messages, reason_code),
      active_run: active_run
    }
  end

  defp stale_active_run?(task, active_run, opts) do
    not orchestrator_running?(task.id, opts) and
      normalize_status(active_run.status) == :executing and
      in_flight_execution?(active_run, opts)
  end

  defp in_flight_execution?(active_run, opts) do
    case Keyword.fetch(opts, :latest_step_execution) do
      {:ok, %StepExecution{} = execution} ->
        execution.status in @in_flight_execution_statuses

      {:ok, nil} ->
        false

      :error ->
        active_run
        |> latest_step_execution()
        |> case do
          %StepExecution{status: status} -> status in @in_flight_execution_statuses
          nil -> false
        end
    end
  end

  defp latest_step_execution(%TaskRun{latest_step_execution: %StepExecution{} = execution}) do
    execution
  end

  defp latest_step_execution(%TaskRun{latest_step_execution_id: execution_id})
       when is_binary(execution_id) do
    Repo.get(StepExecution, execution_id)
  end

  defp latest_step_execution(_active_run), do: nil

  defp active_status?(status), do: TaskRunStatus.active?(normalize_status(status))

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case status do
      "queued" -> :queued
      "executing" -> :executing
      "waiting" -> :waiting
      "stopping" -> :stopping
      "stopped" -> :stopped
      "completed" -> :completed
      "failed" -> :failed
      other -> other
    end
  end

  defp normalize_status(status), do: status

  defp task_completed?(%Task{completed_at: nil, status: status}), do: status == "done"
  defp task_completed?(%Task{}), do: true

  defp missing_workflow?(%Task{workflow_id: nil}), do: true
  defp missing_workflow?(%Task{current_step_id: nil}), do: true
  defp missing_workflow?(%Task{}), do: false

  defp blocked?(task, opts) do
    case Keyword.fetch(opts, :blocked?) do
      {:ok, blocked?} ->
        blocked?

      :error ->
        task
        |> TaskDependencies.get_direct_blockers()
        |> Enum.any?(&is_nil(&1.completed_at))
    end
  end

  defp orchestrator_running?(task_id, opts) do
    case Keyword.fetch(opts, :orchestrator_running?) do
      {:ok, running?} -> running?
      :error -> Registry.lookup(TaskRegistry, task_id) != []
    end
  end

  defp orchestrator_running?(task_id), do: Registry.lookup(TaskRegistry, task_id) != []

  defp active_runs_by_task_id(user_id, task_ids) do
    user_id
    |> Accounts.TaskRuns.list_active_for_tasks(task_ids)
    |> Enum.reduce(%{}, fn task_run, acc -> Map.put_new(acc, task_run.task_id, task_run) end)
  end

  defp active_run_or_nil(%TaskRun{} = task_run) do
    if active_status?(task_run.status), do: task_run, else: nil
  end
end
