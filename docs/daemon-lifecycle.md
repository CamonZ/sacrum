# Daemon Lifecycle: Client Handoff

Supported client behavior for standalone daemon enrollment and the
owner-facing management API. This document intentionally documents only what
the server guarantees; anything not listed here is unsupported.

## Identity and status

A daemon is an owner-scoped identity. Its lifecycle status is one of:

| Status | Meaning |
|--------|---------|
| `pending` | Provisioned but never enrolled. A live registration (bootstrap) token exists. |
| `active` | Enrolled at least once (an access/refresh token pair was issued). |

`status` describes credential-enrollment lifecycle, not connection health.
There is no daemon-level `revoked` or `removed` status. Identity invalidation
is represented by deleting the daemon row.

Timestamps:

- `enrolledAt` — first successful bootstrap exchange; `null` for identities
  that have never enrolled (never fabricated).
- `expiresAt` (bootstrap responses) — the one-time registration token's expiry.
  The registration token is valid for **24 hours** from creation or owner
  rotation. Access tokens issued by exchange/refresh last 1 hour and refresh
  tokens 30 days.

Deletion removes the daemon identity and its credentials. The daemon ID is not
recreated, and a later request with the old ID is treated like any other
unknown identity.

## Credentials and secret handling

A daemon uses three token kinds. All are high-entropy random values stored only
as SHA-256 hashes (never Argon2) and authenticated by an indexed hash lookup.

| Token | Lifetime | Issued by | Authorizes |
|-------|----------|-----------|------------|
| Registration (bootstrap) | 24 hours, one-time | `createDaemon`, `rotateDaemonCredentials` | Only `POST /api/daemon/exchange` |
| Access | 1 hour | exchange, refresh | GraphQL requests and daemon socket connect/join |
| Refresh | 30 days | exchange, refresh | Only `POST /api/daemon/refresh` |

Creating or rotating a daemon issues **only** the registration token; no access
or refresh token exists until it is exchanged. An access token never authorizes
a refresh, a refresh token never authorizes a request or socket connect, and a
registration token authorizes neither.

- Exchange (`POST /api/daemon/exchange`, unauthenticated) takes `daemon_id` and
  `bootstrap_token`, consumes the registration token and returns `daemon_id`,
  `access_token`, `access_token_expires_at`, `refresh_token` and
  `refresh_token_expires_at`. Replaying a consumed token fails with
  `invalid_credentials`.
- Plaintext tokens are shown exactly once, in an exchange or refresh response
  (`Cache-Control: no-store`). They are never returned by metadata reads or
  included in logs; metadata exposes only credential kind, status, expiry and
  revocation/consumption timestamps.
- Exactly one live registration token exists per daemon at any time. If an
  exchange response is lost, the only recovery is owner-initiated rotation,
  which invalidates prior credentials and issues a fresh registration token on
  the same identity.
- Credential-level `revoked` rows remain for rotation history. They do not
  represent a daemon lifecycle state and are all deleted with their daemon.
- Socket connect uses `daemon_id` + `access_token`. Joining `daemon:{daemon_id}`
  revalidates the credential against the database, so a session established
  before deletion, rotation or refresh is terminated on the post-commit
  invalidation message or on the next periodic revalidation.

## Names

- `name` is optional: trimmed, 1..100 characters, unique per owner
  (case-insensitive). Blank strings are rejected, not silently ignored.
- `displayName` is always non-null: the name when set, otherwise a stable
  short-ID fallback derived from the daemon ID. Legacy rows project the same
  fallback.
- Deletion removes the identity; it does not preserve a renamed or terminal
  tombstone.

## Execution concurrency

`maxConcurrency` is an optional positive integer controlling the daemon's
in-memory step-admission budget. A `null` value leaves the daemon unlimited
from its own configuration perspective. The orchestration coordinator pins a
task-run tree to its assigned daemon, and each active step temporarily consumes
one slot from that daemon. Waiting human-input and child steps release their
active slot while retaining the task-tree placement. Accepted work on one
daemon does not consume capacity on another daemon. Owners can set or clear the value with
`setDaemonMaxConcurrency(id:, maxConcurrency:)` and
`clearDaemonMaxConcurrency(id:)`; both mutations are owner-scoped.

Admission status has three meanings: `configured` is the current positive
limit or `null` for unlimited, `in_use` is the number of active step slots
tracked by the in-memory coordinator, and `available` is the remaining
capacity or `null` when unlimited. Lowering a limit does not interrupt existing
steps; it only pauses new admission until occupancy falls below the new limit.
Changing or clearing the limit updates the in-memory admission coordinator;
queued and future reservations use the new value, while existing slots remain
active until their owning steps release them.
The occupancy map is process-local and is rebuilt as orchestration processes
request and release slots; it is not a durable step-attempt ledger.

## Owner management surface (GraphQL)

All management operations require an authenticated account token or a valid
daemon access token. Registration and refresh tokens authorize nothing on this
surface.

| Operation | Contract |
|-----------|----------|
| `createDaemon(name?)` | Omitted name stays compatible; returns `daemon`, one-time `enrollmentToken`, `expiresAt`. |
| `renameDaemon(id, name)` | Shared name policy; omitted `name` leaves the current value unchanged, `name: null` clears the name. |
| `setDaemonMaxConcurrency(id, maxConcurrency)` | Sets a positive per-daemon execution limit and returns the updated daemon. |
| `clearDaemonMaxConcurrency(id)` | Clears the per-daemon execution limit and returns the updated daemon. |
| `unregisterDaemon(id)` | Owner-scoped hard delete. Deletes the identity and cascaded credentials in a locked transaction, then invalidates any connected daemon session after commit. |
| `rotateDaemonCredentials(id)` | New registration token on the same identity; every outstanding access and refresh token (and the live session) is invalidated. Unknown/foreign/deleted IDs are `daemon not found`. |
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
  active credentials (registration, access and refresh), and issues a new
  registration token. Rotation never recreates a
  deleted daemon and cannot issue credentials after deletion wins a race.
- A failed delete leaves the daemon and every credential unchanged because
  the row delete and database cascade are transactional.

## Account fleet realtime channel

Authenticated account clients join `accounts:me` over the existing
user-authenticated socket. Sacrum derives the account exclusively from the
socket's authenticated current user and internally subscribes the channel
process to `account:<user_id>`. The internal topic is not externally
joinable, and standalone daemon principals cannot join `accounts:me`. The
existing `daemon:<daemon_id>` registration/revalidation topic remains the
daemon-authenticated transport and remains unavailable to account clients for
management events.

The post-commit WalEx CDC projector publishes these durable lifecycle events to
the owner's internal account topic, where the `accounts:me` channel forwards
them to that user's active subscribers:

| Event | Meaning |
|-------|---------|
| `daemon_created` | A daemon identity was created. |
| `daemon_updated` | A daemon's durable identity or enrollment lifecycle changed. |
| `daemon_deleted` | A daemon row was hard-deleted. |
| `daemon_metrics` | A connected daemon accepted a report or heartbeat; carries live capabilities, freshness, and derived health. |

Lifecycle payloads have `schema_version: 1` and contain the complete sanitized
identity. Metrics payloads use the same version and are ephemeral direct PubSub
events; they are not persisted or replayed by WalEx. See [Daemon Telemetry Contract](daemon-telemetry-contract.md)
for the report format, freshness thresholds, and exact allowlists.
Daemon status remains `pending` or `active`; hard deletion is represented by
`daemon_deleted`. Credential plaintext, token hashes, and credential rows are
never projected.

## Execution delivery

- Execution commands are transient `run_step` and `cancel_step` broadcasts on the
  authenticated `daemon:<daemon_id>` topic.
- Commands are not replayed on reconnect. `StepExecution` remains the durable
  execution and reporting record, but it is not a command queue.
- Execution reports use the existing GraphQL mutations already consumed by the
  daemon. A standalone daemon sends its access token as
  `Authorization: Bearer <access_token>` together with
  `X-Daemon-ID: <daemon_id>` on `/graphql` requests. Sacrum resolves the
  token to its owning account with a single SHA-256 indexed lookup (no Argon2,
  no transaction, no row lock) and includes the authenticated daemon and
  credential IDs in the GraphQL context, so the same token can be used by the
  daemon's CLI while it works.
- The existing task API still locks workspace changes during an active run.
  Updating a worktree path from an executing daemon is also separate follow-up work.
- The server advertises no endpoints. Daemon base URLs and socket endpoints
  come from client configuration and remain authoritative.
- An access token has the same GraphQL account access as its owning account.
  Registration and refresh tokens never authorize GraphQL.

## Access and refresh tokens

The daemon authenticates every request with its short-lived access token and
calls `POST /api/daemon/refresh` before it expires. Refresh is a separate,
unauthenticated endpoint that takes the **refresh token** (not the possibly
expired access token), so a leaked access token cannot be renewed:

```json
{"daemon_id": "<uuid>", "refresh_token": "<token>"}
```

The response has the same shape as exchange: a new access token plus a rotated
refresh token with their expiries, `Cache-Control: no-store`.

Sockets are tied to their access token, so every refresh (at least hourly)
closes the daemon's live socket(s); the daemon reconnects with the new access
token. Dispatched work is not lost: commands are not replayed, and the durable
`StepExecution` plus snapshot recovery on reconnect remain authoritative (see
Execution delivery).

Rotation rules:

- A refresh issues a new access+refresh pair and immediately revokes **all** of
  the daemon's previous access tokens (live sockets on them are terminated and
  must reconnect with the new access token).
- The presented refresh token is rotated once its successor pair is first used
  (a GraphQL request, a socket connect, or a refresh). From then on it simply
  fails with `invalid_credentials`; there is no revoke-everything reuse
  detection.
- Until then it can be presented again to recover a lost refresh response: that
  issues a new pair and revokes the unused successor pair. Presenting the
  successor starts the next rotation cycle.
- Because of that recovery window a daemon can briefly hold two valid refresh
  tokens (the predecessor and its unused successor); never more.

Rotation, revocation and the daemon row lock run **only** on refresh (and exchange,
owner rotation and deletion). A regular request performs one indexed SELECT.
The only write on the request path is a single idempotent UPDATE the first time
a freshly refreshed access token is used, retiring the predecessor refresh token.

Exchange, refresh, owner rotation and deletion serialize on the daemon row
lock; deletion cascades all credentials and refresh never recreates a deleted
identity. Only the response contains plaintext; metadata and lifecycle/CDC
projections contain neither plaintext nor token hashes.

Invalid, expired, revoked, foreign or deleted tokens return the stable
`invalid_credentials` code (HTTP 401). A token presented with another daemon's
`X-Daemon-ID` is rejected. Temporary database failures return `unavailable`
(HTTP 503 from the token endpoints and during request authentication); callers
may retry with the same refresh token. Expired refresh tokens cannot be used;
the owner must rotate credentials and the daemon re-exchange.

**Deployment is a hard cutover.** The migration deletes all `reconnect` rows
and revokes unconsumed registration tokens, so every enrolled daemon must have
its owner run `rotateDaemonCredentials` and be upgraded to the new daemon build
(release the companion daemon change together with this one). Old and new app
versions must not run side by side. Rolling the migration back is lossy; use a
forward migration instead.

The `renewDaemonCredential` mutation and the `reconnect_token` socket parameter
no longer exist; sockets connect with `access_token`.
