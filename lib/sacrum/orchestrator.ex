defmodule Sacrum.Orchestrator do
  @moduledoc """
  High-level API for managing running TaskOrchestrator instances.

  Stopping an orchestrator halts any in-flight step execution:
  - Marks the in-flight step execution as "cancelled" (matches status in ["started", "in_progress", "waiting"])
  - Broadcasts cancel_step to the daemon (fire-and-forget)
  - Terminates the FSM child
  """

  require Logger

  import Ecto.Query

  alias Sacrum.Orchestrator.{TaskFSMSupervisor, TaskRegistry, TaskRunLifecycle}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution

  @spec stop(Ecto.UUID.t()) :: {:ok, :stopped | :not_running}
  def stop(task_id) when is_binary(task_id) do
    active_task_run = TaskRunLifecycle.fetch_active_for_task(task_id)

    case Registry.lookup(TaskRegistry, task_id) do
      [{pid, _}] ->
        request_task_run_stop(active_task_run)
        cancel_in_flight_execution(task_id, active_task_run)
        mark_task_run_stopped(active_task_run)
        terminate_fsm_child(pid)
        {:ok, :stopped}

      [] ->
        stop_durable_run_without_fsm(active_task_run)
    end
  end

  defp stop_durable_run_without_fsm({:ok, _task_run} = active_task_run) do
    request_task_run_stop(active_task_run)
    mark_task_run_stopped(active_task_run)
    {:ok, :stopped}
  end

  defp stop_durable_run_without_fsm({:error, :not_found}), do: {:ok, :not_running}

  defp request_task_run_stop({:ok, task_run}) do
    case TaskRunLifecycle.mark_stopping(task_run) do
      {:ok, _task_run} ->
        :ok

      {:error, reason} ->
        Logger.error("[Orchestrator.stop] Failed to mark TaskRun stopping: #{inspect(reason)}")
        :ok
    end
  end

  defp request_task_run_stop({:error, :not_found}), do: :ok

  defp mark_task_run_stopped({:ok, task_run}) do
    case TaskRunLifecycle.mark_stopped(task_run) do
      {:ok, _task_run} ->
        :ok

      {:error, reason} ->
        Logger.error("[Orchestrator.stop] Failed to mark TaskRun stopped: #{inspect(reason)}")
        :ok
    end
  end

  defp mark_task_run_stopped({:error, :not_found}), do: :ok

  defp cancel_in_flight_execution(task_id, active_task_run) do
    case find_in_flight_execution(task_id, active_task_run) do
      {:ok, execution} ->
        mark_cancelled(execution)
        broadcast_cancel_step(execution)

      :none ->
        :ok
    end
  end

  defp find_in_flight_execution(_task_id, {:ok, task_run}) do
    query =
      from(e in StepExecution,
        where:
          e.task_run_id == ^task_run.id and
            e.status in ["started", "in_progress", "waiting"],
        order_by: [desc: e.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> :none
      execution -> {:ok, execution}
    end
  end

  defp find_in_flight_execution(task_id, {:error, :not_found}) do
    query =
      from(e in StepExecution,
        where: e.task_id == ^task_id and e.status in ["started", "in_progress", "waiting"],
        order_by: [desc: e.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> :none
      execution -> {:ok, execution}
    end
  end

  defp mark_cancelled(execution) do
    case execution
         |> StepExecution.update_changeset(%{status: "cancelled"})
         |> Repo.update() do
      {:ok, _} ->
        Logger.info("[Orchestrator.stop] Marked execution #{execution.id} as cancelled")

      {:error, reason} ->
        Logger.error(
          "[Orchestrator.stop] Failed to mark execution as cancelled: #{inspect(reason)}"
        )
    end
  end

  defp broadcast_cancel_step(execution) do
    Logger.info("[Orchestrator.stop] Broadcasting cancel_step for execution #{execution.id}")

    task = Repo.get(Sacrum.Repo.Schemas.Task, execution.task_id)

    if task do
      task = Repo.preload(task, :project)

      case task.project do
        %{id: project_id} -> Broadcaster.broadcast_cancel_step(execution, project_id)
        _ -> :ok
      end
    end
  end

  defp terminate_fsm_child(pid) do
    case TaskFSMSupervisor.terminate_child(pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
