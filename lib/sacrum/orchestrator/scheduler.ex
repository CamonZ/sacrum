defmodule Sacrum.Orchestrator.Scheduler do
  @moduledoc """
  Coordinates task scheduling and orchestration lifecycle.
  Skeleton implementation — stubs to be filled in a later ticket.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec schedule_task(map()) :: :ok | {:error, term()}
  def schedule_task(task) do
    GenServer.call(__MODULE__, {:schedule_task, task})
  end

  @spec notify_task_completed(binary(), map()) :: :ok | {:error, term()}
  def notify_task_completed(task_id, result) do
    GenServer.call(__MODULE__, {:notify_task_completed, task_id, result})
  end

  @impl true
  def init(_opts) do
    Logger.info("[Scheduler] Initialized")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:schedule_task, _task}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:notify_task_completed, _task_id, _result}, _from, state) do
    {:reply, :ok, state}
  end
end
