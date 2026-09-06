# Daemon credential persistence and compatibility

Credential rows store only `token_hash`; neither raw bootstrap tokens nor raw
reconnect tokens have a database column. Inspection redacts the hash and the
schema's JSON encoder includes metadata only.

`credential_kind` distinguishes `bootstrap` from `reconnect`. Bootstrap expiry
limits the exchange window, and `consumed_at` records its one-time use. Reconnect
credentials have their own required expiry; consuming or expiring a bootstrap
does not extend or shorten that expiry. Both kinds may be revoked. A credential
is unusable once expired, consumed, or revoked. Atomic exchange must lock and
recheck the bootstrap row; a changeset alone cannot prevent concurrent reuse.

The kind and identity come from trusted structs, while lifecycle functions set
consumption and revocation timestamps. The create changeset retains the existing
hash/expiry/status input contract. Creation with a daemon issues a bootstrap;
rotation retains the daemon ID, revokes all old credentials, and issues a fresh
bootstrap for owner-authorized recovery. These are
persistence contracts; the exchange and socket authentication layers enforce
which kind is accepted at each boundary.

Existing rows become `reconnect`, retaining their exact expiry, active/revoked
status, and revocation timestamp. This preserves their previous reusable scope
without making them permanent or granting bootstrap exchange authority. Legacy
writers that omit the new columns receive the same reconnect default. Operators
should complete deployment of the exchange/authentication implementation before
issuing new bootstrap credentials: old application versions cannot enforce their
one-time semantics.

The first migration adds a non-null constant kind default, nullable consumption
timestamp, allowed-kind constraint, and a daemon/kind/status index. The forward
correction adds allowed-status, revocation/status consistency, and bootstrap-only
consumption constraints. Revoked legacy rows without timestamps remain valid
historical records and remain unusable through their status. Expired rows remain
valid historical records; expiry is evaluated at authentication time.

These migrations use ordinary transactional DDL. Index construction and check
validation scan the table and can hold locks; schedule a maintenance window for
large installations, inspect table size and lock contention first, and do not
assume the isolated development database reflects production volume. The constant
default avoids an application-side backfill. Invalid preexisting statuses or
active rows carrying revocation timestamps must be investigated before deploying
the integrity migration; it intentionally fails rather than changing their
security meaning.

Rolling back only the integrity migration removes checks without changing data.
Rolling back the kind migration loses classification and consumption history;
an old application could accept a consumed bootstrap again. Never perform that
rollback while issued bootstrap credentials remain usable. Prefer a forward fix;
otherwise stop authentication and revoke affected credentials before rollback.


## Exchange and recovery service

`Accounts.Daemons.exchange_bootstrap(daemon_id, bootstrap_token)` returns
`{:ok, daemon, reconnect_token, reconnect_credential}` on success. The metadata
contains its expiry and credential ID; the daemon row supplies the trusted owner.
Invalid, expired, consumed, revoked, or mismatched inputs return
`{:error, :invalid_credentials}`. Persistence validation errors return a changeset.
The reconnect lifetime is 30 days from exchange and is independent of bootstrap
expiry. `verify_token` accepts reconnect credentials only.

Exchange verifies and hashes before acquiring a daemon row lock, then locks and
rechecks the bootstrap and writes consumption plus issuance in one transaction.
Rotation takes the same daemon lock before revoking all credentials and issuing a
bootstrap. Daemon revocation obtains that row lock through its update. This orders
exchange against concurrent rotation/revocation. Socket lifecycle invalidation
must use these persisted revocation states in the follow-up lifecycle work.

A lost successful response cannot be replayed to recover its plaintext. The owner
calls `Accounts.Daemons.rotate(user_id, daemon_id)` and exchanges the newly issued
bootstrap; rotation invalidates the lost reconnect. No plaintext recovery storage
exists. Trusted tests can pass `now: datetime` to exchange or verification;
production callers omit it, checking current UTC after acquiring locks.

## Provisioning and HTTP transport

Authenticated GraphQL `createDaemon` and `rotateDaemonCredentials` retain
`daemon`, `enrollmentToken`, and `serverEndpoint` and add non-null `expiresAt`.
Expiry is returned from the exact credential inserted in the issuance transaction,
so concurrent rotation cannot substitute another credential's timestamp.

`serverEndpoint` is the HTTP(S) base URL, including any nondefault port and reverse
proxy prefix. Set runtime `DAEMON_EXTERNAL_URL`, for example
`https://fleet.example:8443/sacrum`, when public routing differs from the listener.
Without an override the trusted Phoenix endpoint URL supplies the base, including
its configured listener port. Invalid explicit configuration fails closed; neither
Host nor forwarded headers influence issuance. URLs with credentials, query,
fragment, unsupported scheme, invalid port or parent path segments are rejected.
The reverse proxy must strip the configured prefix before forwarding to Phoenix.

Append `/api/daemon/exchange` to the base and POST a body containing exactly
`daemon_id` and `bootstrap_token` (the GraphQL `enrollmentToken`). No account bearer
token is needed. Success returns `daemon_id`, `reconnect_token`, `expires_at`,
`server_endpoint`, and the complete `socket_endpoint` (`ws`/`wss`, matching public
port and prefix, ending in `/socket/websocket`). Query credentials and extra body
fields are rejected. Unrelated GraphQL operations remain account-authenticated.

Malformed shape returns HTTP 400 `invalid_request`; invalid credentials return
401 `invalid_credentials`; configuration/persistence validation failure returns
503 `exchange_unavailable`. Responses use `Cache-Control: no-store`. Credential
parameter names are filtered by Phoenix logging. HTTP exchange credentials belong in the request body, never URL paths or query
strings. Phoenix WebSocket connection parameters use the handshake query string;
reverse proxies and access loggers must omit or redact query strings on
`/socket/websocket` (including any public prefix). Use HTTPS/WSS for remote
connections. Phoenix parameter filtering cannot redact upstream access logs.

## Standalone socket authentication

Connect to the returned `socket_endpoint` with Phoenix socket parameters
`daemon_id` and `reconnect_token`, then join `daemon:<daemon_id>` with an empty
payload. Account tokens continue to use the separate `token` parameter. Mixed
account/daemon authentication parameters are rejected.

The daemon principal carries only the persisted daemon, owner, and credential IDs;
it never synthesizes `current_user` or retains reconnect plaintext in assigns.
Client-supplied owner or credential IDs cannot override the verified identity.
Socket identifiers distinguish account sockets from daemon/credential sockets.
Joining rechecks credential expiry/revocation and daemon revocation, and the topic
must exactly match the authenticated daemon ID. Daemon principals cannot join
project channels. Historical account-authenticated daemon joins still require a
reconnect credential and matching account ownership.

The local single-registration registry rejects duplicate sessions. Channel
termination releases only its own successful registration; failed joins cannot
unregister another session. Disconnect and channel/application process restart do
not invalidate the durable reconnect credential. Bootstrap expiry after exchange
does not affect reconnect authentication. Live-session invalidation on later
rotation/revocation is completed by the lifecycle follow-up.

## Supported operation matrix

| Boundary/operation | Bootstrap | Standalone reconnect | Account API token |
| --- | --- | --- | --- |
| HTTP bootstrap exchange | Once, matching unexpired identity | 401 `invalid_credentials` | Does not substitute for bootstrap |
| Account GraphQL queries/provisioning/rotation/revocation | 401 `Invalid API token` | 401 `Invalid API token` | Existing owner-scoped access |
| Execution/session-log GraphQL mutations | 401 `Invalid API token` | 401 `Invalid API token` | Existing owner-scoped access |
| Socket `daemon:<own-id>` registration | Rejected at connect | Allowed, one live registration | Historical join also requires matching reconnect |
| Other daemon topic | Rejected at connect | `identity_mismatch` | Matching owner and reconnect required |
| Project topic, any `client_type` | Rejected at connect | `forbidden` | Existing owned-project access |
| Daemon topic inbound report/completion/run/cancel/unknown event | No session | `unsupported_operation` | Same explicit unsupported daemon-topic reply |

This matrix covers the existing HTTP GraphQL, bootstrap HTTP transport, and
`/socket` channels. The only supported standalone daemon operation is registration.
No persisted assignment binds a standalone daemon to a current execution in this
scope, so reporting/completion are deliberately unsupported even when the caller
knows a real execution ID. No claimed user, daemon, project, or execution ID grants
additional access. Project assignment and reporting require a separate design that
checks server-owned current execution identity before supporting those operations.
The legacy account project channel's `client_type=daemon` is delivery classification
inside existing account authorization; it does not elevate a standalone principal.
