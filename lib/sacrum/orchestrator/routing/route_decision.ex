defmodule Sacrum.Orchestrator.Routing.RouteDecision do
  @moduledoc """
  Encodes and logs locally evaluated route decisions.
  """

  require Logger

  @doc """
  Encodes the stable target record stored with a deterministic local route audit.
  """
  @spec transition_result(String.t(), String.t()) :: String.t()
  def transition_result(dest_id, transition_type) do
    Jason.encode!(%{"dest_id" => dest_id, "transition_type" => transition_type})
  end

  @doc """
  Logs the route decision for forensic purposes, including handoff keys (not values).
  """
  @spec log_route_decision(String.t(), String.t(), String.t(), String.t(), map() | nil) :: :ok
  def log_route_decision(task_id, execution_id, dest_id, transition_type, handoff) do
    handoff_keys = if is_map(handoff), do: Map.keys(handoff), else: nil

    Logger.info(
      "[TaskOrchestrator:#{task_id}] route decision execution=#{execution_id} " <>
        "dest_id=#{dest_id} transition_type=#{transition_type} handoff_keys=#{inspect(handoff_keys)}"
    )

    :ok
  end
end
