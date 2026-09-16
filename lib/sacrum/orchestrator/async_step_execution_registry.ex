defmodule Sacrum.Orchestrator.AsyncStepExecutionRegistry do
  @moduledoc """
  Registry for supervised direct step execution workers.

  Direct `runStep` workers are not TaskOrchestrators, so they need a separate
  lookup path when a TaskRun is stopped.
  """

  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(_opts), do: Registry.start_link(keys: :unique, name: __MODULE__)

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :permanent,
      shutdown: :infinity
    }
  end
end
