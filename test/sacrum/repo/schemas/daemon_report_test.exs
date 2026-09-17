defmodule Sacrum.Repo.Schemas.DaemonReportTest do
  use ExUnit.Case, async: true

  alias Sacrum.Repo.Schemas.DaemonReport

  test "normalizes the bounded v1 report and drops unknown fields" do
    payload = %{
      "version" => 1,
      "daemon_id" => "11111111-1111-4111-8111-111111111111",
      "daemon_version" => "  v1.2.3  ",
      "os" => "macos",
      "architecture" => "aarch64",
      "host" => "builder-1",
      "started_at" => "2026-09-17T10:00:00Z",
      "capabilities" => %{
        "providers" => %{
          "openai" => true
        },
        "harnesses" => %{"claude_code" => false}
      },
      "project_ids" => ["must-not-be-stored"]
    }

    assert {:ok, report} = DaemonReport.parse(payload)
    assert report.version == 1
    assert report.daemon_id == "11111111-1111-4111-8111-111111111111"
    assert report.daemon_version == "v1.2.3"
    assert report.os == "macos"
    assert report.architecture == "aarch64"
    assert report.host == "builder-1"
    assert report.started_at == ~U[2026-09-17 10:00:00.000000Z]

    assert report.capabilities == %{
             "providers" => %{"openai" => true},
             "harnesses" => %{"claude_code" => false}
           }

    refute inspect(report) =~ "project_ids"
  end

  test "accepts legacy version zero reports with only known fields" do
    assert {:ok, report} =
             DaemonReport.parse(%{"version" => 0, "daemon_version" => "legacy"})

    assert report.version == 0
    assert report.daemon_version == "legacy"
    assert report.capabilities == nil
  end

  test "missing version remains compatible with the original liveness shape" do
    assert {:ok, report} = DaemonReport.parse(%{})
    assert report.version == 0
    assert report.capabilities == nil
  end

  test "rejects unsupported versions, malformed values, and oversized input" do
    assert DaemonReport.parse(%{"version" => 2}) == {:error, :invalid_report}

    assert DaemonReport.parse(%{"os" => 123}) == {:error, :invalid_report}

    assert DaemonReport.parse(%{"started_at" => "not-a-datetime"}) ==
             {:error, :invalid_report}

    assert DaemonReport.parse(%{"capabilities" => "not-an-object"}) ==
             {:error, :invalid_report}

    assert DaemonReport.parse(%{"unknown" => String.duplicate("x", 32_769)}) ==
             {:error, :invalid_report}
  end

  test "merges reports into ephemeral metrics and preserves metadata on heartbeats" do
    now = ~U[2026-09-17 10:00:05Z]
    later = ~U[2026-09-17 10:00:10Z]

    assert {:ok, report} =
             DaemonReport.parse(%{
               "version" => 1,
               "daemon_version" => "v1.2.3",
               "capabilities" => %{"providers" => %{"openai" => true}}
             })

    metrics = DaemonReport.merge_metrics(report, nil, false, now)
    assert metrics.report_version == 1
    assert metrics.daemon_version == "v1.2.3"
    assert metrics.last_seen_at == now

    assert {:ok, heartbeat} = DaemonReport.parse(%{"version" => 0})
    metrics = DaemonReport.merge_metrics(heartbeat, metrics, true, later)
    assert metrics.report_version == 1
    assert metrics.daemon_version == "v1.2.3"
    assert metrics.capabilities == %{"providers" => %{"openai" => true}}
    assert metrics.last_seen_at == later
  end
end
