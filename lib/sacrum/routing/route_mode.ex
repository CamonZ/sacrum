defmodule Sacrum.Routing.RouteMode do
  @moduledoc """
  Selects deterministic or legacy routing from persisted route-step data.

  A present `route_config` always selects deterministic routing. Otherwise a
  present prompt uses the legacy model path. Invalid configuration is rejected
  at persist time; a drifted row still fails closed at runtime rather than
  falling back to its prompt.
  """

  alias Sacrum.Routing.RouteConfig

  @type mode :: {:legacy, String.t()} | {:deterministic, RouteConfig.t()}
  @type error :: :route_not_configured | RouteConfig.error()

  @spec routing_mode(map()) :: {:ok, mode()} | {:error, error()}
  def routing_mode(step) when is_map(step) do
    select(Map.get(step, :route_config), Map.get(step, :prompt))
  end

  defp select(route_config, prompt) do
    case decode_config(route_config) do
      {:ok, program} ->
        {:ok, {:deterministic, program}}

      :absent ->
        legacy_or_unconfigured(prompt, :route_not_configured)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_config(nil), do: :absent

  defp decode_config(route_config) do
    case RouteConfig.decode(route_config) do
      {:ok, program} -> {:ok, program}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_or_unconfigured(nil, reason), do: {:error, reason}
  defp legacy_or_unconfigured(prompt, _reason), do: {:ok, {:legacy, prompt}}
end
