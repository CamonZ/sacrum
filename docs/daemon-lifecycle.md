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

`status` describes credential-enrollment lifecycle, not connection health.
There is no daemon-level `revoked` or `removed` status. Identity invalidation
is represented by deleting the daemon row.

Timestamps:

- `enrolledAt` — first successful bootstrap exchange; `null` for identities
  that have never enrolled (never fabricated).
- `expiresAt` (bootstrap responses) — the one-time enrollment token's expiry.
  Reconnect credentials issued by exchange last 30 days.

Deletion removes the daemon identity and its credentials. The daemon ID is not
recreated, and a later request with the old ID is treated like any other
unknown identity.

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
- Credential-level `revoked` rows remain supported for rotation history. They
  do not represent a daemon lifecycle state and are all deleted with their
  daemon.
- Socket connect uses `daemon_id` + `reconnect_token`. Joining
  `daemon:{daemon_id}` revalidates the credential against the database, so a
  session established before deletion is terminated on the post-commit
  invalidation message or on the next periodic revalidation.

## Names

- `name` is optional: trimmed, 1..100 characters, unique per owner
  (case-insensitive). Blank strings are rejected, not silently ignored.
- `displayName` is always non-null: the name when set, otherwise a stable
  short-ID fallback derived from the daemon ID. Legacy rows project the same
  fallback.
- Deletion removes the identity; it does not preserve a renamed or terminal
  tombstone.

## Owner management surface (GraphQL)

All management operations require an authenticated account token; bootstrap
and reconnect credentials authorize nothing on this surface.

| Operation | Contract |
|-----------|----------|
| `createDaemon(name?)` | Omitted name stays compatible; returns `daemon`, one-time `enrollmentToken`, `expiresAt`. |
| `renameDaemon(id, name)` | Shared name policy; omitted `name` leaves the current value unchanged, `name: null` clears the name. |
| `unregisterDaemon(id)` | Owner-scoped hard delete. Deletes the identity and cascaded credentials in a locked transaction, then invalidates any connected daemon session after commit. |
| `rotateDaemonCredentials(id)` | New bootstrap on the same identity; prior credentials (and the live session) are invalidated. Unknown/foreign/deleted IDs are `daemon not found`. |
| `daemons` | Active fleet. Deleted identities are absent. |
| `daemon(id)` / `daemonEnrollmentMetadata(id)` | Owner-scoped reads. Deleted identities are not readable; foreign IDs are indistinguishable from unknown IDs. |

The unregister operation is serialized with exchange and rotation by locking
the daemon row before checking the optional daemon-keyed active-work guard and
deleting it. A successful commit is the boundary for session invalidation.
Database deletion alone does not synchronously terminate an already-connected
Phoenix channel; the channel receives invalidation and revalidates its
persisted daemon and credential identity before shutting down.

## Errors and rotation behavior

- Naming violations surface as field-scoped GraphQL errors on `name`.
- Delete and rotation are owner-scoped; unknown, foreign and already-deleted
  identities are intentionally indistinguishable.
- Rotation preserves the daemon identity and `enrolledAt`, revokes its prior
  active credentials, and issues a new bootstrap. Rotation never recreates a
  deleted daemon and cannot issue credentials after deletion wins a race.
- A failed delete leaves the daemon and every credential unchanged because
  the row delete and database cascade are transactional.

## Intentionally unsupported

- Daemon sockets do not execute, report or observe project work. All
  execution/reporting events on `daemon:*` topics reply
  `unsupported_operation`. There is no second source of execution truth.
- The server advertises no endpoints. Daemon base URLs and socket endpoints
  come from client configuration and remain authoritative.
- Standalone credentials never expand into account, project or management
  access.
