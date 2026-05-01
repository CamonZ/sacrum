defmodule Sacrum.Orchestrator do
  @moduledoc "High-level API for managing running TaskOrchestrator instances."

  alias Sacrum.Orchestrator.TaskFSMSupervisor
  alias Sacrum.Orchestrator.TaskRegistry

  @spec stop(Ecto.UUID.t()) :: {:ok, :stopped | :not_running}
  def stop(task_id) when is_binary(task_id) do
    case Registry.lookup(TaskRegistry, task_id) do
      [{pid, _}] ->
        case TaskFSMSupervisor.terminate_child(pid) do
          :ok -> {:ok, :stopped}
          {:error, :not_found} -> {:ok, :not_running}
        end

      [] ->
        {:ok, :not_running}
    end
  end
end
