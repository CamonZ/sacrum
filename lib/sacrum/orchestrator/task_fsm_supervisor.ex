defmodule Sacrum.Orchestrator.TaskFSMSupervisor do
  @moduledoc """
  DynamicSupervisor for TaskOrchestrator gen_statem processes.
  """

  use DynamicSupervisor

  require Logger

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("[TaskFSMSupervisor] Initialized")
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_child(term()) :: {:ok, pid()} | {:error, term()}
  def start_child(child_spec) do
    Logger.info(
      "[TaskFSMSupervisor] Starting child for task #{inspect(child_spec, pretty: true)}"
    )

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @spec terminate_child(pid()) :: :ok | {:error, :not_found}
  def terminate_child(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end
end
