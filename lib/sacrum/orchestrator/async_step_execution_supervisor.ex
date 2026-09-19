defmodule Sacrum.Orchestrator.AsyncStepExecutionSupervisor do
  use DynamicSupervisor

  alias Sacrum.Orchestrator.{AsyncStepExecution, AsyncStepExecutionRegistry, ExecutionPool}

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @spec start_execution(binary(), binary(), binary(), binary()) ::
          {:ok, pid()} | {:error, term()}
  def start_execution(execution_id, user_id, project_id, task_run_id) do
    start_execution(execution_id, user_id, project_id, task_run_id, ExecutionPool, [])
  end

  @spec start_execution(binary(), binary(), binary(), binary(), GenServer.server()) ::
          {:ok, pid()} | {:error, term()}
  def start_execution(execution_id, user_id, project_id, task_run_id, pool) do
    start_execution(execution_id, user_id, project_id, task_run_id, pool, [])
  end

  @spec start_execution(binary(), binary(), binary(), binary(), GenServer.server(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_execution(execution_id, user_id, project_id, task_run_id, pool, admission_opts) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {AsyncStepExecution, {execution_id, user_id, project_id, task_run_id, pool, admission_opts}}
    )
  end

  @doc "Cancel a queued request belonging to a direct step execution."
  @spec cancel_execution(binary()) :: :ok
  def cancel_execution(execution_id) when is_binary(execution_id) do
    case execution_pid(execution_id) do
      {pid, pool} -> ExecutionPool.cancel_request(pool, pid)
      nil -> :ok
    end
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  defp execution_pid(execution_id) do
    case Registry.lookup(AsyncStepExecutionRegistry, execution_id) do
      [{pid, pool}] -> {pid, pool}
      [] -> nil
    end
  end
end
