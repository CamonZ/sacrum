# Daemon Telemetry Contract

This is the Sacrum-side contract for the authenticated daemon fleet report.
There is no separate `sacrumd` process. The existing standalone daemon joins
`daemon:<daemon_id>` with its reconnect credential and sends telemetry on that
authenticated channel.

## Transport

After joining successfully, a daemon may send:

| Event | Payload | Purpose |
| --- | --- | --- |
| `report` | Versioned report object | Startup, reconnect, and periodic metadata/capability snapshot |
| `heartbeat` | `{}` or a report-compatible object | Liveness refresh; optional metadata is merged when present |

The Phoenix transport keepalive (`phx_heartbeat` on the `phoenix` topic) is
separate. It keeps the WebSocket open but does not update daemon fleet
`last_seen_at`.

Successful application messages receive an acknowledgement:

```json
{"accepted":true,"report_version":1}
```

An invalid report receives `invalid_report`. A session that fails credential
revalidation is closed without accepting the report.

## Report format

Version 1 is intentionally small and bounded:

```json
{
  "version": 1,
  "daemon_id": "uuid (optional)",
  "daemon_version": "vtb-daemon version",
  "os": "operating system",
  "architecture": "host architecture",
  "host": "host name",
  "started_at": "RFC3339 timestamp",
  "capabilities": {
    "providers": {"openai": true, "anthropic": false},
    "harnesses": {"codex": true, "claude_code": true}
  }
}
```

Capability values are readiness booleans. Missing capability groups or entries
remain unknown. Version 0, and a missing version for legacy daemons, are
accepted. A `heartbeat` does not change the stored report version when it has
no version of its own.

The server rejects payloads over 32 KiB, payloads with more than 64 top-level
keys, strings over 256 characters, and capability groups over 32 entries.
Unknown top-level fields are ignored. Raw reports, credentials, token hashes,
executable paths, diagnostics, project identifiers, capacity, active-work,
slot, and queue counts are never persisted or projected.

## Live report and health

Sacrum keeps only the latest normalized report in the daemon connection's
in-memory registration. It is discarded when the daemon disconnects; no report
or telemetry history is persisted. Each accepted message updates
`last_seen_at`; report metadata is merged so a legacy heartbeat cannot erase
newer metadata. The server derives health using the documented 90-second online
and 300-second offline thresholds:

| Condition | `connection_status` | `health` | Reason |
| --- | --- | --- | --- |
| Never enrolled | `pending` | `pending` | `not_enrolled` |
| Enrolled, no report | `offline` | `offline` | `no_report` |
| Last report age ≤ 90 seconds and every known capability is ready | `online` | `healthy` | `null` |
| Last report age ≤ 90 seconds with unknown capability data | `online` | `degraded` | `capabilities_unknown` |
| Last report age ≤ 90 seconds with a known unavailable capability | `online` | `degraded` | `capability_not_ready` |
| Age > 90 and ≤ 300 seconds | `stale` | `stale` | `stale_heartbeat` |
| Age > 300 seconds | `offline` | `offline` | `offline_heartbeat` |

The GraphQL `daemons` list and `daemon(id:)` detail query return the same
owner-scoped snapshot: durable lifecycle identity plus the current in-memory
metrics when the daemon is connected. Disconnected daemons have no live report
and derive to `offline` (or `pending` when never enrolled). These queries are
authoritative for initial load and reconnect; the GUI should also tolerate the
ephemeral metrics event being missed while disconnected.

## GUI lifecycle and live metrics events

The WalEx consumer watches `daemons` for durable lifecycle changes only.
Lifecycle changes are projected as complete sanitized `daemon_*` replacements
on the owner's internal `account:<user_id>` topic. Accepted reports and
heartbeats are broadcast separately as `daemon_metrics` on that same topic.
`daemon_metrics` is ephemeral and is not replayed from WalEx or Postgres.
Authenticated GUI clients receive both event types only through `accounts:me`.
They never join daemon topics or the internal account topic.

Every accepted heartbeat produces a live metrics event so subscribers can
refresh liveness immediately. A GUI that misses one can use `last_seen_at` and
the thresholds above. Every account payload uses the explicit allowlist and
`schema_version: 1`.
