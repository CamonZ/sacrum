defmodule Sacrum.Orchestrator.AsyncStepExecutionSupervisor do
  use DynamicSupervisor

  alias Sacrum.Orchestrator.AsyncStepExecution

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @spec start_execution(binary(), binary(), binary(), binary()) ::
          {:ok, pid()} | {:error, term()}
  def start_execution(execution_id, user_id, project_id, task_run_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {AsyncStepExecution, {execution_id, user_id, project_id, task_run_id}}
    )
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)
end
