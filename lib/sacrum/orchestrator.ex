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

  alias Sacrum.Orchestrator.{TaskFSMSupervisor, TaskRegistry}
  alias Sacrum.Orchestrator.TaskRuns.{Lookup, StateTransitions}
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.{StepExecution, TaskRun}

  @typep active_task_run :: {:ok, TaskRun.t()} | {:error, :not_found}
  @typep in_flight_execution :: {:ok, StepExecution.t()} | :none

  @spec stop(Ecto.UUID.t()) :: {:ok, :stopped | :not_running} | {:error, term()}
  def stop(task_id) when is_binary(task_id) do
    active_task_run = Lookup.fetch_active_for_task(task_id)

    case Registry.lookup(TaskRegistry, task_id) do
      [{pid, _}] ->
        in_flight_execution = find_in_flight_execution(task_id, active_task_run)

        case commit_stop(active_task_run, in_flight_execution) do
          {:ok, changes} ->
            broadcast_cancelled_execution(changes)
            terminate_fsm_child(pid)
            {:ok, :stopped}

          {:error, reason} ->
            Logger.error("[Orchestrator.stop] Failed to persist stop: #{inspect(reason)}")
            {:error, reason}
        end

      [] ->
        stop_durable_run_without_fsm(active_task_run)
    end
  end

  @spec stop_durable_run_without_fsm(active_task_run()) ::
          {:ok, :stopped | :not_running} | {:error, term()}
  defp stop_durable_run_without_fsm({:ok, _task_run} = active_task_run) do
    case commit_stop(active_task_run, :none) do
      {:ok, _changes} ->
        {:ok, :stopped}

      {:error, reason} ->
        Logger.error("[Orchestrator.stop] Failed to persist durable stop: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp stop_durable_run_without_fsm({:error, :not_found}), do: {:ok, :not_running}

  @spec commit_stop(active_task_run(), in_flight_execution()) :: {:ok, map()} | {:error, term()}
  defp commit_stop(active_task_run, in_flight_execution) do
    Repo.transaction(fn ->
      with {:ok, changes} <- maybe_stop_task_run(active_task_run, %{}),
           {:ok, changes} <- maybe_cancel_execution(in_flight_execution, changes) do
        changes
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec maybe_stop_task_run(active_task_run(), map()) :: {:ok, map()} | {:error, term()}
  defp maybe_stop_task_run({:ok, task_run}, changes) do
    attrs = %{stop_requested_at: task_run.stop_requested_at || DateTime.utc_now()}

    task_run
    |> StateTransitions.stopped_changeset(attrs)
    |> Repo.update()
    |> put_transaction_change(changes, :task_run)
  end

  defp maybe_stop_task_run({:error, :not_found}, changes), do: {:ok, changes}

  @spec maybe_cancel_execution(in_flight_execution(), map()) :: {:ok, map()} | {:error, term()}
  defp maybe_cancel_execution({:ok, execution}, changes) do
    execution
    |> StepExecution.update_changeset(%{status: "cancelled"})
    |> Repo.update()
    |> put_transaction_change(changes, :execution)
  end

  defp maybe_cancel_execution(:none, changes), do: {:ok, changes}

  @spec put_transaction_change({:ok, term()} | {:error, term()}, map(), atom()) ::
          {:ok, map()} | {:error, term()}
  defp put_transaction_change({:ok, value}, changes, key), do: {:ok, Map.put(changes, key, value)}
  defp put_transaction_change({:error, reason}, _changes, _key), do: {:error, reason}

  @spec find_in_flight_execution(binary(), active_task_run()) :: in_flight_execution()
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

  @spec broadcast_cancelled_execution(map()) :: term()
  defp broadcast_cancelled_execution(%{execution: execution}) do
    Logger.info("[Orchestrator.stop] Marked execution #{execution.id} as cancelled")
    broadcast_cancel_step(execution)
  end

  defp broadcast_cancelled_execution(_changes), do: :ok

  @spec broadcast_cancel_step(StepExecution.t()) :: term()
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

  @spec terminate_fsm_child(pid()) :: :ok
  defp terminate_fsm_child(pid) do
    case TaskFSMSupervisor.terminate_child(pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
