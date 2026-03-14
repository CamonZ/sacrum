defmodule Sacrum.Orchestrator.Supervisor do
  @moduledoc """
  Root supervisor for the orchestration subsystem.

  Uses :rest_for_one so that an ExecutionPool crash restarts
  the Scheduler and all FSM processes downstream.
  """

  use Supervisor

  require Logger

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Sacrum.Orchestrator.ExecutionPool, []},
      {Sacrum.Orchestrator.Scheduler, []},
      {Sacrum.Orchestrator.TaskFSMSupervisor, []}
    ]

    Logger.info("[Orchestrator.Supervisor] Initialized with rest_for_one strategy")
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
