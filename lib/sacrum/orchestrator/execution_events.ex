defmodule Sacrum.Orchestrator.ExecutionEvents do
  @moduledoc """
  Internal execution-status notifications for TaskOrchestrator processes.

  GUI-facing StepExecution projections are emitted from WalEx CDC. The
  orchestrator still needs a local signal when a daemon persists an execution
  status update, so it listens on a private execution topic instead of the
  ProjectChannel topic used by clients.
  """

  alias Sacrum.Repo.Schemas.StepExecution

  @spec subscribe(binary()) :: :ok | {:error, term()}
  def subscribe(execution_id) when is_binary(execution_id) do
    Phoenix.PubSub.subscribe(Sacrum.PubSub, topic(execution_id))
  end

  @spec broadcast_status_changed(StepExecution.t()) :: :ok | {:error, term()}
  def broadcast_status_changed(%StepExecution{id: id, status: status})
      when is_binary(id) and is_binary(status) do
    broadcast_status_changed(id, status)
  end

  @spec broadcast_status_changed(binary(), String.t()) :: :ok | {:error, term()}
  def broadcast_status_changed(execution_id, status)
      when is_binary(execution_id) and is_binary(status) do
    Phoenix.PubSub.broadcast(
      Sacrum.PubSub,
      topic(execution_id),
      {:step_execution_status_changed, %{id: execution_id, status: status}}
    )
  end

  defp topic(execution_id), do: "step_execution:#{execution_id}"
end
