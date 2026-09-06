# Daemon Lifecycle: Client Handoff

Supported client behavior for standalone daemon enrollment and the
owner-facing management API. This document intentionally documents only what
the server guarantees; anything not listed here is unsupported.

## Identity and status

A daemon is an owner-scoped identity. Its lifecycle status is one of:

| Status | Meaning |
|--------|---------|
| `pending` | Provisioned but never enrolled. A live bootstrap credential exists. |
| `active` | Enrolled at least once (a reconnect credential was issued). |
| `revoked` | Terminal. All credentials invalidated; no exchange, reconnect or rotation succeeds. |
| `removed` | Terminal soft tombstone. Same refusals as `revoked`; additionally excluded from the fleet list. |

Timestamps:

- `enrolledAt` — first successful bootstrap exchange; `null` for identities
  that have never enrolled (never fabricated).
- `removedAt` — tombstone time, set only on successful unregister.
- `expiresAt` (bootstrap responses) — the one-time enrollment token's expiry.
  Reconnect credentials issued by exchange last 30 days.

Terminal states (`revoked`, `removed`) are permanent. No credential
operation, refresh or rename returns an identity to service.

## Credentials and secret handling

- Bootstrap exchange (`POST /api/daemon/exchange`) is unauthenticated and
  one-time: `daemon_id` + `bootstrap_token` yield a reconnect token and its
  expiry. Replaying a consumed bootstrap fails with `invalid_credentials`.
- The reconnect token is shown exactly once, at exchange time. It is never
  present in any query, mutation, metadata projection or log; metadata
  exposes only credential kind, status, expiry and revocation/consumption
  timestamps.
- Exactly one live bootstrap exists per daemon at any time. If an exchange
  response is lost, the only recovery is owner-initiated rotation, which
  invalidates prior credentials and issues a fresh bootstrap on the same
  identity.
- Socket connect uses `daemon_id` + `reconnect_token`. Joining
  `daemon:{daemon_id}` revalidates the credential against the database, so a
  session established before a revocation still terminates on join or on the
  next periodic revalidation.

## Names

- `name` is optional: trimmed, 1..100 characters, unique per owner
  (case-insensitive). Blank strings are rejected, not silently ignored.
- `displayName` is always non-null: the name when set, otherwise a stable
  short-ID fallback derived from the daemon id. Legacy rows project the same
  fallback.
- Terminal identities keep their name for audit and refuse renames.

## Owner management surface (GraphQL)

All management operations require an authenticated account token; bootstrap
and reconnect credentials authorize nothing on this surface.

| Operation | Contract |
|-----------|----------|
| `createDaemon(name?)` | Omitted name stays compatible; returns `daemon`, one-time `enrollmentToken`, `expiresAt`. |
| `renameDaemon(id, name)` | Shared name policy; `name: null` clears the name. |
| `revokeDaemon(id)` | Terminal, idempotent. Kills the daemon's connected session post-commit. |
| `rotateDaemonCredentials(id)` | New bootstrap; prior credentials (and the live session) invalidated. |
| `unregisterDaemon(id)` | See refusal semantics below. Idempotent on already-removed rows. |
| `daemons` | Active fleet: tombstones excluded after successful removal only. |
| `daemon(id)` / `daemonEnrollmentMetadata(id)` | Owner-scoped reads; tombstones remain readable; foreign ids are indistinguishable from unknown ids. |

## Unregister refusal semantics

Removal preserves the row, credential audit and execution history (soft
tombstone; credentials are revoked, never deleted). It is refused
conservatively whenever work safety cannot be established:

- `daemon not found` — unknown id or another owner's daemon (no disclosure).
- `daemon has an active session; disconnect it before unregistering` — a
  session is currently connected. Disconnection alone does not make an
  enrolled daemon removable.
- `daemon has enrollment history and cannot be unregistered until work
  ownership is established` — any reconnect credential (of any status) or a
  consumed bootstrap exists. Unregistering an idle enrolled daemon
  **awaits reliable daemon-keyed work-ownership integration**; until then the
  server cannot prove absence of in-flight work.
- Only never-enrolled provisioning is removable today.

## Errors and idempotency

- Naming violations surface as field-scoped GraphQL errors on `name`.
- Domain refusals use the stable messages above; unknown and foreign
  identities are intentionally indistinguishable.
- `revokeDaemon` and `unregisterDaemon` are idempotent: repeating them
  returns the terminal state instead of an error.
- Lost exchange responses are not replayable; recovery is rotation only.

## Intentionally unsupported

- Daemon sockets do not execute, report or observe project work. All
  execution/reporting events on `daemon:*` topics reply
  `unsupported_operation`. There is no second source of execution truth.
- The server advertises no endpoints. Daemon base URLs and socket endpoints
  come from client configuration and remain authoritative.
- Standalone credentials never expand into account, project or management
  access.
