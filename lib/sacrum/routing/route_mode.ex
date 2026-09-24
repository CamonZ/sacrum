defmodule Sacrum.Routing.RouteMode do
  @moduledoc """
  Selects deterministic routing from persisted route-step data.

  Route steps require a valid `route_config`. Prompts do not select a routing
  mode; a missing or invalid configuration fails closed.
  """

  alias Sacrum.Routing.RouteConfig

  @type mode :: {:deterministic, RouteConfig.t()}
  @type error :: :route_config_required | RouteConfig.error()

  @spec routing_mode(map()) :: {:ok, mode()} | {:error, error()}
  def routing_mode(step) when is_map(step) do
    case Map.get(step, :route_config) do
      nil ->
        {:error, :route_config_required}

      route_config ->
        case RouteConfig.decode(route_config) do
          {:ok, program} -> {:ok, {:deterministic, program}}
          {:error, reason} -> {:error, reason}
        end
    end
  end
end
