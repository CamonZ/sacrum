defmodule Sacrum.PendingExecutionTimeoutChecker do
  @moduledoc """
  GenServer that periodically checks for pending step executions that have exceeded the timeout threshold.

  When an execution is pending for longer than the configured timeout duration, it is marked as failed
  with an output message indicating no daemon picked it up.
  """

  use GenServer

  require Logger
  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution

  # Run check every 5 seconds
  @check_interval_ms 5_000

  # Client API

  @doc """
  Start the timeout checker as part of the application supervision tree.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Schedule the first check
    schedule_check()
    {:ok, nil}
  end

  @impl true
  def handle_info(:check_timeouts, state) do
    check_and_fail_timed_out_executions()
    schedule_check()
    {:noreply, state}
  end

  # Private Functions

  defp schedule_check do
    Process.send_after(self(), :check_timeouts, @check_interval_ms)
  end

  defp check_and_fail_timed_out_executions do
    timeout_ms = Application.get_env(:sacrum, :pending_execution_timeout_ms, 60_000)
    cutoff_time = DateTime.add(DateTime.utc_now(), -timeout_ms, :millisecond)

    # Query for pending executions older than the timeout
    query =
      from(execution in StepExecution,
        where: execution.status == "pending" and execution.inserted_at < ^cutoff_time
      )

    timed_out_executions = Repo.all(query)

    Enum.each(timed_out_executions, fn execution ->
      fail_execution_with_timeout(execution)
    end)

    case timed_out_executions do
      [] ->
        :ok

      _ ->
        Logger.info(
          "[PendingExecutionTimeoutChecker] Marked #{Enum.count(timed_out_executions)} executions as failed due to timeout"
        )
    end
  end

  defp fail_execution_with_timeout(execution) do
    # Update the execution to failed status with timeout message
    attrs = %{
      status: "failed",
      output: "No daemon picked up execution within the timeout period"
    }

    # We bypass the user_id check since this is an internal operation
    changeset = StepExecution.update_changeset(execution, attrs)

    case Repo.update(changeset) do
      {:ok, updated_execution} ->
        # Broadcast the status change
        Broadcaster.broadcast_step_execution_direct(updated_execution, :step_execution_status_changed)
        Logger.info("[PendingExecutionTimeoutChecker] Failed execution #{execution.id} due to timeout")

      {:error, reason} ->
        Logger.error(
          "[PendingExecutionTimeoutChecker] Failed to mark execution #{execution.id} as failed: #{inspect(reason)}"
        )
    end
  end
end
