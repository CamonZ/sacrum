defmodule Sacrum.Orchestrator.Routing.RouteMode do
  @moduledoc """
  Selects the one routing mode for a persisted route step.

  A non-blank prompt keeps the legacy daemon-driven route. Otherwise the
  route must use a valid deterministic configuration; configuration errors do
  not fall back to the prompt path.
  """

  alias Sacrum.Orchestrator.Routing.{RouteConfig, RouteContext}

  @type mode :: {:legacy, String.t()} | {:deterministic, RouteConfig.t()}
  @type error :: :route_not_configured | RouteConfig.error() | RouteContext.error()

  @doc """
  Returns whether a prompt selects the legacy route mode.
  """
  @spec legacy_prompt?(term()) :: boolean()
  def legacy_prompt?(prompt) when is_binary(prompt), do: String.trim(prompt) != ""
  def legacy_prompt?(_prompt), do: false

  @doc """
  Selects legacy or deterministic routing from a route step's persisted data.
  """
  @spec routing_mode(%{prompt: term(), route_config: term()}) :: {:ok, mode()} | {:error, error()}
  def routing_mode(%{prompt: prompt, route_config: route_config}) when is_binary(prompt) do
    if legacy_prompt?(prompt) do
      {:ok, {:legacy, prompt}}
    else
      deterministic_mode(route_config)
    end
  end

  def routing_mode(%{prompt: prompt}) when is_binary(prompt) do
    if legacy_prompt?(prompt) do
      {:ok, {:legacy, prompt}}
    else
      deterministic_mode(nil)
    end
  end

  def routing_mode(%{route_config: route_config}) do
    deterministic_mode(route_config)
  end

  def routing_mode(_step), do: {:error, :route_not_configured}

  defp deterministic_mode(nil), do: {:error, :route_not_configured}

  defp deterministic_mode(route_config) do
    with {:ok, program} <- RouteConfig.decode(route_config),
         :ok <- RouteContext.validate(program) do
      {:ok, {:deterministic, program}}
    else
      {:error, reason} -> {:error, reason}
    end
  end
end
