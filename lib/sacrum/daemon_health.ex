defmodule Sacrum.DaemonHealth do
  @moduledoc "Server-owned daemon freshness and capability health."

  @online_seconds 90
  @stale_seconds 300

  @spec derive(map(), map() | nil, DateTime.t()) :: %{
          connection_status: String.t(),
          health: String.t(),
          health_reason: String.t() | nil
        }
  def derive(%{enrolled_at: nil}, _metrics, _now),
    do: status("pending", "pending", "not_enrolled")

  def derive(%{enrolled_at: _}, nil, _now),
    do: status("offline", "offline", "no_report")

  def derive(_daemon, %{last_seen_at: nil}, _now),
    do: status("offline", "offline", "no_report")

  def derive(_daemon, metrics, now) do
    age = max(DateTime.diff(now, metrics.last_seen_at, :second), 0)

    cond do
      age > @stale_seconds -> status("offline", "offline", "offline_heartbeat")
      age > @online_seconds -> status("stale", "stale", "stale_heartbeat")
      true -> fresh_status(metrics.capabilities)
    end
  end

  defp fresh_status(nil), do: status("online", "degraded", "capabilities_unknown")

  defp fresh_status(capabilities) when is_map(capabilities) do
    values =
      capabilities
      |> Map.values()
      |> Enum.filter(&is_map/1)
      |> Enum.flat_map(&Map.values/1)

    cond do
      values == [] -> status("online", "degraded", "capabilities_unknown")
      Enum.any?(values, &(&1 == false)) -> status("online", "degraded", "capability_not_ready")
      Enum.all?(values, &(&1 == true)) -> status("online", "healthy", nil)
      true -> status("online", "degraded", "capabilities_unknown")
    end
  end

  defp fresh_status(_capabilities), do: status("online", "degraded", "capabilities_unknown")

  defp status(connection_status, health, health_reason),
    do: %{connection_status: connection_status, health: health, health_reason: health_reason}
end
