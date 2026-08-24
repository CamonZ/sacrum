defmodule Sacrum.Orchestrator.Routing.RouteMode do
  @moduledoc """
  Selects legacy or deterministic routing from persisted route-step data.
  """

  alias Sacrum.Orchestrator.Routing.RouteConfig

  @type mode :: {:legacy, String.t()} | {:deterministic, RouteConfig.t()}
  @type error :: :route_not_configured | RouteConfig.error()

  @spec routing_mode(map()) :: {:ok, mode()} | {:error, error()}
  def routing_mode(step) do
    prompt = Map.get(step, :prompt)

    if legacy_prompt?(prompt) do
      {:ok, {:legacy, prompt}}
    else
      deterministic_mode(Map.get(step, :route_config))
    end
  end

  defp legacy_prompt?(prompt), do: not is_nil(prompt)

  defp deterministic_mode(nil), do: {:error, :route_not_configured}

  defp deterministic_mode(route_config) do
    case RouteConfig.decode(route_config) do
      {:ok, program} -> {:ok, {:deterministic, program}}
      {:error, reason} -> {:error, reason}
    end
  end
end
