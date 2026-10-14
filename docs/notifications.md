# Notifications

Daemon scripts can publish durable, Markdown notifications such as
"Task [Ship it](vtb://task/<uuid>) has completed". Sacrum stores each one,
broadcasts it on the project channel after commit, and serves it from a
paginated history query so a GUI that was disconnected can recover it. The
owner can mark notifications read.

Code: `Sacrum.Repo.Schemas.Notification`, `Sacrum.Repo.Notifications`,
`Sacrum.Accounts.Notifications`, `SacrumWeb.Graphql.Types.NotificationTypes`.

## Model

One `notifications` table:

| Column | Notes |
| --- | --- |
| `id` | UUID. Stable across the mutation result, history, and realtime events. |
| `user_id` | The authenticated caller. |
| `project_id` | From the request. A composite foreign key, `(project_id, user_id)` → `projects (id, user_id)`, guarantees the project belongs to the user. |
| `message` | Markdown, at most 4,096 bytes, not blank. Stored byte-for-byte. |
| `severity` | `info`, `success`, `warning`, or `error`. |
| `inserted_at` | Server timestamp (microseconds). |
| `read_at` | When the owner marked the notification read; `null` while unread. |

A notification belongs to a project and its user and nothing else. It does not
reference tasks, TaskRuns, or step executions; the message can link to them.

The message, severity, and ownership never change after publication; `read_at`
is the only mutable field. Each notification has exactly one owner, so read
state lives on the row rather than in a per-user table. Sacrum does not keep a
link table, title, references array, dismiss state, or idempotency key.
Dismissing (hiding) a notification is GUI-local.

## Publishing

```graphql
mutation {
  publishNotification(
    projectId: "76267e24-a4e4-4230-88f1-33bd69cfd5ff"
    message: "Artifact [report](vtb://artifact/9b7c1a52-1f0e-4f43-a0c7-2b8d7e6b1c10) has been added to task [Ship it](vtb://task/3f1d9f6e-5c1b-4f8e-9f55-0b6f0c7d2a11)."
    severity: "success"
  ) { id projectId message severity insertedAt readAt }
}
```

The caller authenticates with an account API token or a daemon reconnect
credential; both resolve to the owning account. Sacrum inserts the
notification with the caller as `user_id` and the requested `projectId`; there
is no separate ownership lookup. The `(project_id, user_id)` foreign key
rejects an unknown project or one owned by another account with
`project_id: does not exist`. The changeset rejects an invalid `message` or
`severity`, and the `UUID4` scalar rejects a malformed `projectId` before the
resolver runs.

A rejected request persists nothing and broadcasts nothing. Each successful
call creates a new notification; two identical calls create two
notifications. There is no exactly-once guarantee.

## Message Markdown and Link Destinations

The message is data. Sacrum does not render it, parse its links, or check that
link targets exist when it is published. Whoever follows a link is checked
by the normal entity read APIs at that moment, so a link to a deleted or
foreign entity just fails to resolve.

Destinations use the Vertebrae typed URI convention `vtb://<type>/<uuid>`:

| Destination | URI | Resolved with |
| --- | --- | --- |
| Task | `vtb://task/<task uuid>` | `task(id:)` |
| Ticket | `vtb://ticket/<task uuid>` | `task(id:)` |
| Epic | `vtb://epic/<task uuid>` | `task(id:)` |
| Artifact | `vtb://artifact/<artifact uuid>` | `artifact(id:)` |

`task`, `ticket`, and `epic` are existing Vertebrae GUI link types; all three
are task rows that differ only in `level`. `vtb://artifact/<uuid>` is the
proposed artifact destination. The GUI link parser does not recognize it yet;
adding it is follow-up consumer work.

Example messages:

```markdown
Task [Ship it](vtb://task/3f1d9f6e-5c1b-4f8e-9f55-0b6f0c7d2a11) has completed.
Artifact [report](vtb://artifact/9b7c1a52-1f0e-4f43-a0c7-2b8d7e6b1c10) has been added to task [Ship it](vtb://task/3f1d9f6e-5c1b-4f8e-9f55-0b6f0c7d2a11).
Ticket [Notifications](vtb://ticket/27018ff0-d663-4fb4-93ad-0a65777cbd71) needs your review.
```

## Realtime Delivery

The committed row is projected by WalEx CDC on `project:<project_id>` to
default clients (never daemon clients):

```json
{
  "event": "notification_created",
  "payload": {
    "schema_version": 1,
    "id": "0aec77c7-319d-449d-a3b3-d6d8cdb6ffad",
    "project_id": "76267e24-a4e4-4230-88f1-33bd69cfd5ff",
    "message": "Task [Ship it](vtb://task/3f1d9f6e-5c1b-4f8e-9f55-0b6f0c7d2a11) has completed.",
    "severity": "success",
    "inserted_at": "2026-10-14T20:37:02.698001Z",
    "read_at": null
  }
}
```

`notification_updated` carries the same payload when a notification is marked
read, so every open client can apply `read_at`. `notification_deleted` carries the same payload from the before image when a
notification row is removed, including database cascades.

## History and Reconnect Recovery

```graphql
query {
  projectNotifications(
    projectId: "76267e24-a4e4-4230-88f1-33bd69cfd5ff"
    afterInsertedAt: "2026-10-14T20:37:02.698001Z"
    afterId: "0aec77c7-319d-449d-a3b3-d6d8cdb6ffad"
    limit: 50
    unreadOnly: false
  ) {
    hasMore
    notifications { id projectId message severity insertedAt readAt }
  }
}
```

Results are ordered by `insertedAt` ascending, then `id` ascending, and start
strictly after the `(afterInsertedAt, afterId)` cursor. The two cursor
arguments must be supplied together; omit both to start from the oldest
notification. `limit` defaults to 50 and must be between 1 and 200.
`unreadOnly: true` skips notifications that have been marked read. Fetch the
next page with the last returned notification as the cursor while `hasMore`
is true. A project outside the caller's account returns `not_found`.

To recover after reconnecting, a client takes the newest notification it holds
and requests history after it. `inserted_at` is assigned before commit, so a
notification can commit slightly after a later-stamped one. Clients should
rewind the cursor timestamp by a few seconds and deduplicate by `id` when
merging history with realtime events. Deduplicating by `id` also covers
duplicate deliveries.

## Read State

```graphql
mutation {
  markNotificationsRead(ids: ["0aec77c7-319d-449d-a3b3-d6d8cdb6ffad"]) { id readAt }
}
```

`markNotificationsRead` sets `read_at` on the caller's unread notifications
among `ids` (1 to 200 IDs) and returns the caller's matching notifications.
It is idempotent: a notification keeps its first `read_at`. Unknown IDs and
other accounts' notifications are ignored and left out of the result. Each
notification that becomes read emits `notification_updated`. There is no
"mark unread" operation.

## Retention and Deletion

Notifications are kept, read or unread, until their project or account is
deleted; both cascade and emit `notification_deleted`. Deleting a task, TaskRun,
or execution mentioned in a message does not affect the notification, and the
link then fails to resolve.
