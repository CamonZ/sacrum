defmodule Sacrum.DaemonHealthTest do
  use ExUnit.Case, async: true

  alias Sacrum.DaemonHealth

  @daemon %{enrolled_at: ~U[2026-09-17 10:00:00Z]}
  @now ~U[2026-09-17 10:00:00Z]

  test "pending means the daemon has never successfully enrolled" do
    assert DaemonHealth.derive(%{enrolled_at: nil}, nil, @now) == %{
             connection_status: "pending",
             health: "pending",
             health_reason: "not_enrolled"
           }
  end

  test "a fresh report is healthy only when all known capabilities are ready" do
    telemetry = %{last_seen_at: @now, capabilities: %{"providers" => %{"openai" => true}}}

    assert DaemonHealth.derive(@daemon, telemetry, @now) == %{
             connection_status: "online",
             health: "healthy",
             health_reason: nil
           }

    unknown = %{telemetry | capabilities: nil}
    assert DaemonHealth.derive(@daemon, unknown, @now).health == "degraded"
    assert DaemonHealth.derive(@daemon, unknown, @now).health_reason == "capabilities_unknown"

    not_ready = %{telemetry | capabilities: %{"harnesses" => %{"claude_code" => false}}}
    assert DaemonHealth.derive(@daemon, not_ready, @now).health == "degraded"
    assert DaemonHealth.derive(@daemon, not_ready, @now).health_reason == "capability_not_ready"
  end

  test "freshness transitions at the documented stale and offline thresholds" do
    stale_at = DateTime.add(@now, 91, :second)
    offline_at = DateTime.add(@now, 301, :second)
    telemetry = %{last_seen_at: @now, capabilities: %{"providers" => %{"openai" => true}}}

    assert DaemonHealth.derive(@daemon, telemetry, stale_at) == %{
             connection_status: "stale",
             health: "stale",
             health_reason: "stale_heartbeat"
           }

    assert DaemonHealth.derive(@daemon, telemetry, offline_at) == %{
             connection_status: "offline",
             health: "offline",
             health_reason: "offline_heartbeat"
           }
  end

  test "an enrolled daemon with no accepted report is offline and never healthy" do
    assert DaemonHealth.derive(@daemon, nil, @now) == %{
             connection_status: "offline",
             health: "offline",
             health_reason: "no_report"
           }
  end
end
