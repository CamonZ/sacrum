defmodule Sacrum.Routing.RouteMode do
  @moduledoc """
  Selects deterministic or legacy routing from persisted route-step data.

  A present `route_config` is authoritative. Otherwise a present prompt uses
  the legacy model path.
  """

  alias Sacrum.Routing.RouteConfig

  @type mode :: {:legacy, String.t()} | {:deterministic, RouteConfig.t()}
  @type error :: :route_not_configured | RouteConfig.error()

  @spec routing_mode(map()) :: {:ok, mode()} | {:error, error()}
  def routing_mode(step) when is_map(step) do
    select(Map.get(step, :route_config), Map.get(step, :prompt))
  end

  defp select(nil, prompt), do: legacy_or_unconfigured(prompt, :route_not_configured)

  defp select(route_config, _prompt) do
    case RouteConfig.decode(route_config) do
      {:ok, program} ->
        {:ok, {:deterministic, program}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp legacy_or_unconfigured(nil, reason), do: {:error, reason}
  defp legacy_or_unconfigured(prompt, _reason), do: {:ok, {:legacy, prompt}}
end
