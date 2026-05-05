defmodule Sacrum.Orchestrator.Routing.RouteDecision do
  @moduledoc """
  Parses, validates, and persists route step output decisions.
  """

  require Logger

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.StructuredOutput
  alias Sacrum.Repo.Schemas.StepExecution

  @valid_transition_types ["intra_workflow", "inter_workflow"]

  @doc """
  Parses raw route step output into a decoded JSON map.

  Returns `{:error, :missing_route_output}` for nil, `{:error, :invalid_json_output}`
  when decoding fails.
  """
  @spec parse_route_output(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def parse_route_output(nil) do
    Logger.warning("[TaskOrchestrator] parse_route_output got nil output on route step")
    {:error, :missing_route_output}
  end

  def parse_route_output(output) when is_binary(output) do
    case StructuredOutput.decode(output) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, reason} ->
        Logger.warning(
          "[TaskOrchestrator] parse_route_output decode failed reason=#{inspect(reason)} " <>
            "output_preview=#{inspect(String.slice(output, 0, 200))}"
        )

        {:error, :invalid_json_output}
    end
  end

  @doc """
  Extracts routing data from decoded route output.

  Expects `"transition_to"` (binary) and `"transition_type"` (one of
  `#{inspect(@valid_transition_types)}`). `"handoff"` is optional.
  """
  @spec extract_routing_data(map()) :: {:ok, map()} | {:error, term()}
  def extract_routing_data(%{"transition_to" => dest_id, "transition_type" => type} = decoded)
      when is_binary(dest_id) and type in @valid_transition_types do
    {:ok, %{dest_id: dest_id, transition_type: type, handoff: Map.get(decoded, "handoff")}}
  end

  def extract_routing_data(decoded) when is_map(decoded),
    do: {:error, :invalid_route_output_format}

  def extract_routing_data(_), do: {:error, :route_output_not_map}

  @doc """
  Persists the route decision to the StepExecution record.

  The existing StepExecution schema stores `transition_result` as a string, so
  the normalized route decision is JSON-encoded for that legacy field.
  """
  @spec persist_route_decision(
          Sacrum.Repo.Schemas.StepExecution.t(),
          String.t(),
          String.t()
        ) :: :ok | {:error, term()}
  def persist_route_decision(execution, dest_id, transition_type) do
    case Accounts.StepExecutions.update(execution, route_decision_attrs(dest_id, transition_type)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[TaskOrchestrator] persist_route_decision failed execution=#{execution.id} " <>
            "dest_id=#{dest_id} transition_type=#{transition_type} reason=#{inspect(reason)}"
        )

        {:error, {:route_decision_persist_failed, reason}}
    end
  end

  @spec route_decision_changeset(StepExecution.t(), String.t(), String.t()) :: Ecto.Changeset.t()
  def route_decision_changeset(%StepExecution{} = execution, dest_id, transition_type) do
    StepExecution.update_changeset(execution, route_decision_attrs(dest_id, transition_type))
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

  defp route_decision_attrs(dest_id, transition_type) do
    %{
      transition_result:
        Jason.encode!(%{"dest_id" => dest_id, "transition_type" => transition_type})
    }
  end
end
