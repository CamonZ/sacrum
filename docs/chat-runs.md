# Chat Runs Contract

This document defines the MVP architecture for backend-owned chat runs. The
full target model uses `ChatRun` as the durable user-facing conversation/work
container. It can answer questions, research, plan, propose artifacts, and
create tasks. One `ChatRun` may contain multiple `ChatSession` records over
time.

V0 is deliberately smaller and session-first: Sacrum persists
`chat_sessions`, `chat_messages`, and `chat_events` only. V0 does not require a
`chat_runs` table, artifacts, task-origin links, history listing, archive, or
delete behavior. `ChatRun` remains the planned higher-level container, not a
prerequisite for the first durable live chat transcript spine.

The intended mapping mirrors the existing execution model:

| Task workflow model | Chat model | Meaning |
|---------------------|------------|---------|
| `TaskRun` | `ChatRun` | Durable run/work container |
| `StepExecution` | `ChatSession` | One execution/session attempt inside the run |
| `SessionLog` | `ChatMessage` | Public transcript/log entry for that session |

Chat runs are not `TaskRun`s. A `TaskRun` executes an existing task through an
assigned workflow. A `ChatRun` may create tasks before any task or workflow
exists, so it needs its own persistence and visibility model.

## Goals

- Preserve a user-visible chat transcript.
- Keep internal prompts, tool traces, command logs, and engine provenance out of
  public APIs.
- Link tasks created by a chat run back to the originating chat.
- Provide an MVP GraphQL and channel contract without rewriting the current
  workflow engine.
- Leave a migration path to app-owned workflows, Jido, or Runic if chat-backed
  planning later needs a general graph runtime.

## Non-Goals

- Do not model chat work as a `TaskRun`.
- Do not expose raw prompts, model/tool traces, harness command logs, or
  Runic/Jido provenance to user-facing clients.
- Do not require app-owned workflow definitions for the MVP.
- Do not change `TaskRun`, `StepExecution`, or existing workflow semantics.

## Minimal Entities

| Concept | Public Meaning | Internal Meaning |
|---------|----------------|------------------|
| `ChatRun` | Planned user-facing conversation/work container | Future stable owner for sessions, messages, events, artifacts, and created-task links |
| `ChatSession` | V0 live chat session/attempt | Backend execution/session attempt; session-first in V0, later attachable to a `ChatRun` |
| `ChatMessage` | Chat message visible to the user | Public transcript entry attached to a `ChatSession`; analogous to `SessionLog` |
| `Artifact` | Durable output usable across Sacrum | Public or internal output linked to chat runs, chat sessions, task runs, step executions, or tasks |
| `ArtifactLink` | Where an artifact came from or should be shown | Generic relationship between an artifact and another resource |
| `ArtifactDecision` | Review decision for an artifact | Approval/rejection/needs-revision audit trail |
| `ChatEvent` | Progress/update stream | Append-only event log with public and internal payload boundaries |
| `ChatInvestigationRequest` | Optional visible request to investigate something | Optional sub-work item for future decomposition |
| `ChatRunTask` | Link between a chat run and a task it created or changed | First-class relationship used by clients and audits |

The full user-facing product surface should be a chat run with messages,
artifacts, status updates, and task links. The V0 surface can start as a live
chat session transcript while preserving the later ChatRun migration path.

A chat run is not a single task or a single unit of work. One `ChatRun` can
produce zero, one, or many tasks over time, across multiple `ChatSession`s and
multiple approved artifacts.

## Status Ownership

Keep the existing run model split intact:

| Field | Answers | Must Not Answer |
|-------|---------|-----------------|
| `ChatRun.status` | What should the chat UI show for the whole conversation/work run? | Existing task workflow state |
| `ChatSession.status` | What is one chat session attempt doing now? | Whole chat run outcome |
| `TaskRun.status` | What is automation doing for an existing task? | Chat state |
| `StepExecution.status` | What happened to one workflow step attempt? | Chat session outcome |

Suggested MVP values:

```text
ChatRun.status:
- queued
- running
- waiting
- cancelling
- cancelled
- completed
- failed

ChatSession.status:
- queued
- running
- waiting
- cancelling
- cancelled
- completed
- failed
```

`ChatRun.status` is the public chat summary. `ChatSession.status` is the
session-attempt state. A run can have many historical sessions, but normally has
at most one active session.

## Persistence

Use UUID primary keys and `utc_datetime_usec` timestamps, matching the rest of
the repo.

V0 persists only the session-level spine. The V0 tables are scoped directly by
`user_id` and `project_id`, with messages and events attached to
`chat_session_id`. Future migrations can add `chat_runs` and backfill or link
sessions without changing the V0 public transcript/event records.

V0 chat session deletion is a hard delete of the `chat_sessions` row after
scoping by authenticated `user_id`, `project_id`, and `chat_session_id`.
`chat_messages` and `chat_events` use `ON DELETE CASCADE`, so deleting the
session also removes its public transcript and event rows. Deleted sessions
must not appear in project `chatSessions` history or scoped session fetches.

### `chat_runs`

Planned stable user-facing chat identity and durable work container. This table
is not required for the V0 transcript spine.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Primary key |
| `project_id` | uuid | Required, scoped to one project |
| `user_id` | uuid | Owner |
| `title` | text | User-facing title, generated or user edited |
| `status` | text | `queued`, `running`, `waiting`, `cancelling`, `cancelled`, `completed`, `failed` |
| `active_chat_session_id` | uuid | Nullable pointer to active session |
| `last_message_at` | utc_datetime_usec | Sorting sessions by recent chat activity |
| `started_at` / `ended_at` | utc_datetime_usec | Run lifecycle |
| `stop_requested_at` | utc_datetime_usec | Cancellation request timestamp |
| `outcome_kind` | text | Public-safe outcome code such as `completed`, `cancelled`, `failed` |
| `outcome_context` | jsonb | Public-safe identifiers and summary data only |
| `public_metadata` | jsonb | Client-safe metadata only |
| `archived` | boolean | Hide from default lists |
| `inserted_at` / `updated_at` | utc_datetime_usec | Standard timestamps |

### `chat_sessions`

Backend execution/session attempts. In V0, the session is the persisted live
chat owner. In the fuller model, sessions attach to a chat run. This is the
chat-side equivalent of `StepExecution`.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Primary key |
| `chat_run_id` | uuid | Planned with `ChatRun`; absent in V0 |
| `project_id` | uuid | Denormalized for project channel and authorization |
| `user_id` | uuid | Owner |
| `status` | text | `queued`, `running`, `waiting`, `cancelling`, `cancelled`, `completed`, `failed` |
| `session_kind` | text | `planning`, `investigation`, `task_generation`, or future engine kind |
| `started_at` / `ended_at` | utc_datetime_usec | Session lifecycle |
| `stop_requested_at` | utc_datetime_usec | Cancellation request timestamp |
| `engine_kind` | text | `native_planner` for MVP; future `workflow`, `jido`, `runic` |
| `engine_session_ref` | text | Nullable internal reference to a future engine run/session |
| `definition_ref` | text | Nullable internal reference to future app-owned definition |
| `public_metadata` | jsonb | Client-safe metadata only |
| `inserted_at` / `updated_at` | utc_datetime_usec | Standard timestamps |

Do not put raw prompts, command output, full model traces, or Runic graph
provenance in public fields. Store those in internal-only event payloads or
separate operator-only trace storage.

### `chat_messages`

Public transcript entries.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Primary key |
| `chat_run_id` | uuid | Planned with `ChatRun`; absent in V0 |
| `chat_session_id` | uuid | Required |
| `project_id` | uuid | Denormalized authorization/sorting |
| `user_id` | uuid | Owner |
| `role` | text | `user`, `assistant`, or `status` |
| `content` | text | Public-safe chat content |
| `content_format` | text | `plain`, `markdown`, or future structured format |
| `client_message_id` | text | Optional idempotency key for user sends |
| `metadata` | jsonb | Public-safe metadata only |
| `inserted_at` / `updated_at` | utc_datetime_usec | Standard timestamps |

`chat_messages` is not a prompt table. System/developer prompts, model input
bundles, tool request/response bodies, shell logs, and raw traces must not be
stored here.

### `artifacts`

Durable outputs that can be used across Sacrum. Artifacts are not owned by chat
only; they can be produced by a `ChatSession`, `TaskRun`, `StepExecution`, task,
or future execution surface.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Primary key |
| `project_id` | uuid | Denormalized authorization |
| `user_id` | uuid | Owner |
| `artifact_type` | text | `task_draft`, `plan`, `research_summary`, `diff_summary`, etc. |
| `artifact_state` | text | `draft`, `pending_approval`, `approved`, `applied`, `rejected` |
| `title` | text | Public title |
| `content` | text | Public-safe artifact body when textual |
| `data` | jsonb | Public-safe structured data |
| `storage_ref` | text | Optional external/blob reference for larger artifacts |
| `visibility` | text | `public` or `internal` |
| `redaction_state` | text | `not_needed`, `redacted`, `blocked` |
| `inserted_at` / `updated_at` | utc_datetime_usec | Standard timestamps |

Public GraphQL must return only artifacts whose `visibility == "public"`.
Internal artifacts may exist for operator debugging but must not appear in
default user queries or channel events.

### `artifact_links`

Generic relationship between an artifact and the resource that produced it,
shows it, or uses it.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Primary key |
| `artifact_id` | uuid | Required |
| `subject_type` | text | `chat_run`, `chat_session`, `chat_message`, `task`, `task_run`, `step_execution` |
| `subject_id` | uuid | Required |
| `relationship_kind` | text | `produced_by`, `attached_to`, `source_for`, `result_of`, `supersedes` |
| `project_id` | uuid | Denormalized authorization |
| `user_id` | uuid | Owner |
| `metadata` | jsonb | Public-safe link metadata |
| `inserted_at` / `updated_at` | utc_datetime_usec | Standard timestamps |

Use links instead of adding artifact foreign keys to every domain table. A chat
query can project artifacts linked to a `ChatRun` and its `ChatSession`s, while
TaskRun and StepExecution queries can project their own linked artifacts.

### `artifact_decisions`

Review decisions for artifacts. Keep decisions separate from `artifact_links`
so structural relationships do not become a catch-all state machine.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Primary key |
| `artifact_id` | uuid | Required |
| `subject_type` | text | Optional context such as `chat_run`, `task`, `step_execution` |
| `subject_id` | uuid | Nullable context id |
| `decision_kind` | text | `approved`, `rejected`, `rejected_with_comments`, `needs_revision` |
| `decided_by_user_id` | uuid | Required |
| `comments` | text | Nullable reviewer comments |
| `metadata` | jsonb | Public-safe decision metadata |
| `inserted_at` / `updated_at` | utc_datetime_usec | Standard timestamps |

`artifacts.artifact_state` stores the current summary state. `artifact_decisions`
stores the audit trail.

### `chat_events`

Append-only event stream for progress, audit, and operator diagnostics.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Primary key |
| `chat_run_id` | uuid | Planned with `ChatRun`; absent in V0 |
| `chat_session_id` | uuid | Required in V0; nullable later for run-level events |
| `project_id` | uuid | Denormalized authorization/channel routing |
| `user_id` | uuid | Owner |
| `event_type` | text | Stable event name |
| `visibility` | text | `public` or `internal` |
| `public_payload` | jsonb | Safe payload used by GraphQL/channel serializers |
| `internal_payload` | jsonb | Operator-only trace/provenance payload |
| `inserted_at` | utc_datetime_usec | Append timestamp |

Serializer rule: public APIs read only `public_payload` for events marked
`public`. Internal payloads are never copied into user-facing channel payloads,
GraphQL types, or generated messages.

### `chat_investigation_requests`

Optional MVP table. Add it only if the planner needs durable sub-requests before
a general workflow/graph engine exists.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Primary key |
| `chat_run_id` | uuid | Required |
| `chat_session_id` | uuid | Nullable owner session |
| `requested_by_message_id` | uuid | Nullable user/assistant message source |
| `project_id` | uuid | Denormalized authorization |
| `user_id` | uuid | Owner |
| `subject` | text | Public subject |
| `scope` | jsonb | Public-safe search/repo scope |
| `status` | text | `queued`, `running`, `completed`, `failed`, `cancelled` |
| `result_artifact_id` | uuid | Nullable public result |
| `internal_payload` | jsonb | Operator-only trace input/output |
| `inserted_at` / `updated_at` | utc_datetime_usec | Standard timestamps |

If planning work stays simple, skip this table and represent progress with
`chat_events` plus public artifacts.

### `chat_run_tasks`

First-class relationship from a chat run to tasks created or changed from
that conversation.

| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Primary key |
| `chat_run_id` | uuid | Required |
| `chat_session_id` | uuid | Nullable session that created the link |
| `task_id` | uuid | Required |
| `source_message_id` | uuid | Nullable message that requested/approved creation |
| `source_artifact_id` | uuid | Nullable task draft or plan artifact |
| `relationship_kind` | text | `created`, `updated`, `suggested`, `referenced` |
| `created_by` | text | `planner`, `user`, or future system actor |
| `metadata` | jsonb | Public-safe link metadata |
| `inserted_at` / `updated_at` | utc_datetime_usec | Standard timestamps |

The relationship is intentionally one-to-many from run to tasks. Do not add
a unique constraint on `chat_run_id`; that would incorrectly limit a chat run
to one created task or one unit of work. Use a partial unique index only
to ensure that an individual created task has one origin chat run:

```sql
CREATE UNIQUE INDEX chat_run_tasks_one_created_origin
ON chat_run_tasks (task_id)
WHERE relationship_kind = 'created';
```

Clients should use this relationship, not task title heuristics, to answer
"where did this task come from?"

## GraphQL Contract

GraphQL names follow existing camelCase conventions. All public results must be
scoped to the authenticated user and project.

### Public Types

```graphql
type ChatRun {
  id: ID!
  projectId: ID!
  title: String
  status: String!
  activeChatSession: ChatSessionSummary
  lastMessageAt: DateTime
  publicMetadata: Json
  archived: Boolean!
  sessions: [ChatSession!]!
  messages(limit: Int, after: DateTime): [ChatMessage!]!
  artifacts: [Artifact!]!
  taskLinks: [ChatRunTask!]!
  createdTasks: [Task!]!
  insertedAt: DateTime!
  updatedAt: DateTime!
}

type ChatSessionSummary {
  id: ID!
  chatRunId: ID!
  projectId: ID!
  status: String!
  sessionKind: String
  startedAt: DateTime
  endedAt: DateTime
  stopRequestedAt: DateTime
}

type ChatSession {
  id: ID!
  chatRunId: ID!
  projectId: ID!
  status: String!
  sessionKind: String
  startedAt: DateTime
  endedAt: DateTime
  stopRequestedAt: DateTime
  messages: [ChatMessage!]!
  artifacts: [Artifact!]!
  insertedAt: DateTime!
  updatedAt: DateTime!
}

type ChatMessage {
  id: ID!
  chatRunId: ID!
  chatSessionId: ID!
  role: String!
  content: String!
  contentFormat: String!
  metadata: Json
  insertedAt: DateTime!
  updatedAt: DateTime!
}

type Artifact {
  id: ID!
  artifactType: String!
  artifactState: String!
  title: String
  content: String
  data: Json
  storageRef: String
  redactionState: String
  insertedAt: DateTime!
  updatedAt: DateTime!
}

type ChatEvent {
  id: ID!
  chatRunId: ID!
  chatSessionId: ID
  eventType: String!
  payload: Json
  insertedAt: DateTime!
}

type ChatRunTask {
  id: ID!
  chatRunId: ID!
  chatSessionId: ID
  taskId: ID!
  sourceMessageId: ID
  sourceArtifactId: ID
  relationshipKind: String!
  createdBy: String
  metadata: Json
  task: Task!
  insertedAt: DateTime!
  updatedAt: DateTime!
}

type Task {
  chatOrigin: ChatRunTask
}
```

`ChatEvent.payload` maps to `chat_events.public_payload`, never
`internal_payload`.

### Queries

```graphql
query ChatRuns($projectId: Uuid4!, $archived: Boolean, $limit: Int, $after: DateTime) {
  chatRuns(projectId: $projectId, archived: $archived, limit: $limit, after: $after) {
    id
    title
    status
    lastMessageAt
    activeChatSession { id status startedAt }
    createdTasks { id shortId title }
  }
}

query ChatRun($id: Uuid4!) {
  chatRun(id: $id) {
    id
    title
    status
    messages { id role content contentFormat insertedAt }
    artifacts { id artifactType artifactState title content data redactionState }
    taskLinks {
      id
      relationshipKind
      sourceMessageId
      sourceArtifactId
      task { id shortId title }
    }
  }
}

query ChatEvents($chatRunId: Uuid4!, $after: DateTime) {
  chatEvents(chatRunId: $chatRunId, after: $after) {
    id
    eventType
    payload
    insertedAt
  }
}
```

Task detail should expose the originating chat run link:

```graphql
query TaskOrigin($taskId: Uuid4!) {
  task(id: $taskId) {
    id
    shortId
    title
    chatOrigin {
      id
      chatSessionId
      chatRunId
      sourceMessageId
      sourceArtifactId
      relationshipKind
    }
  }
}
```

### Mutations

```graphql
mutation CreateChatRun($input: CreateChatRunInput!) {
  createChatRun(input: $input) {
    id
    title
    status
    activeChatSession { id status }
    messages { id role content insertedAt }
  }
}

input CreateChatRunInput {
  projectId: Uuid4!
  title: String
  initialMessage: String
  publicMetadata: Json
  startSession: Boolean = true
  clientMessageId: String
}
```

`createChatRun` creates the run, optionally creates the first `ChatSession`,
and optionally inserts the initial user message.

```graphql
mutation StartChatSession($input: StartChatSessionInput!) {
  startChatSession(input: $input) {
    id
    chatRunId
    status
    sessionKind
    startedAt
  }
}

input StartChatSessionInput {
  chatRunId: Uuid4!
  sessionKind: String = "planning"
}
```

`startChatSession` starts a backend planning attempt for an existing chat run
without adding a new user message. Use it for explicit retry/resume actions,
artifact follow-up work, or system-triggered continuation.

```graphql
mutation SendChatMessage($input: SendChatMessageInput!) {
  sendChatMessage(input: $input) {
    message {
      id
      role
      content
      insertedAt
    }
    chatRun {
      id
      status
      activeChatSession { id status }
    }
  }
}

input SendChatMessageInput {
  chatRunId: Uuid4!
  content: String!
  contentFormat: String = "markdown"
  clientMessageId: String
  startSession: Boolean = true
}
```

`sendChatMessage` appends a public user message and, by default, starts a new
chat session for the run. Use `clientMessageId` as an idempotency key.

```graphql
mutation CancelChatRun($chatRunId: Uuid4!) {
  cancelChatRun(chatRunId: $chatRunId) {
    id
    status
    stopRequestedAt
  }
}
```

`cancelChatRun` requests cancellation of the active session for that run and
moves the run into a stopping/cancelled lifecycle.

```graphql
mutation ApproveArtifact($input: ApproveArtifactInput!) {
  approveArtifact(input: $input) {
    artifact {
      id
      artifactType
      artifactState
      updatedAt
    }
    createdTasks {
      id
      shortId
      title
    }
    taskLinks {
      id
      taskId
      relationshipKind
      sourceArtifactId
    }
  }
}

input ApproveArtifactInput {
  artifactId: Uuid4!
  approvalNote: String
  apply: Boolean = true
}
```

`approveArtifact` marks a public artifact as approved and, when
`apply: true`, applies the approved artifact through the server-side chat planning
service. For a `task_draft` artifact, applying means creating the corresponding
`Task` records and `ChatRunTask` links transactionally, then moving the
artifact to `applied`. With `apply: false`, the artifact remains `approved`.
Persist `approvalNote`, when present, as a public chat event or public-safe
artifact metadata. The mutation must reject internal, blocked, already applied,
or cross-user artifacts.

Task creation from a chat planner should call the server-side chat planning
service, which creates `Task` records and `ChatRunTask` links in the same
transaction.
Do not rely on clients to backfill the origin link after task creation succeeds.

## Channel Contract

Use the existing `project:<project_id>` channel for public MVP chat events.
Default clients receive public chat events. Daemon clients should not receive
chat events unless a later worker protocol needs them.

Payloads are snake_case, matching the existing channel contract.

| Event | When | Payload |
|-------|------|---------|
| `chat_run_created` | Run created | `ChatRunChannelPayload` |
| `chat_run_updated` | Run status, title, archive state, or active session changed | `ChatRunChannelPayload` |
| `chat_session_created` | Session created under a run | `ChatSessionChannelPayload` |
| `chat_session_updated` | Session status/outcome changed | `ChatSessionChannelPayload` |
| `chat_message_created` | Public chat message inserted | `ChatMessageChannelPayload` |
| `artifact_created` | Public artifact inserted | `ArtifactChannelPayload` |
| `artifact_updated` | Public artifact state or public fields changed | `ArtifactChannelPayload` |
| `chat_event_created` | Public event inserted | `ChatEventChannelPayload` |
| `chat_task_link_created` | Task linked to chat run | `ChatRunTaskChannelPayload` |

```ts
type ChatRunChannelPayload = {
  id: string;
  project_id: string;
  title: string | null;
  status: "queued" | "running" | "waiting" | "cancelling" | "cancelled" | "completed" | "failed";
  active_chat_session_id: string | null;
  last_message_at: string | null;
  public_metadata: Record<string, unknown> | null;
  archived: boolean;
  inserted_at: string;
  updated_at: string;
};

type ChatSessionChannelPayload = {
  id: string;
  chat_run_id: string;
  project_id: string;
  status: "queued" | "running" | "waiting" | "cancelling" | "cancelled" | "completed" | "failed";
  session_kind: string | null;
  started_at: string | null;
  ended_at: string | null;
  stop_requested_at: string | null;
  inserted_at: string;
  updated_at: string;
};

type ChatMessageChannelPayload = {
  id: string;
  chat_run_id: string;
  chat_session_id: string;
  role: "user" | "assistant" | "status";
  content: string;
  content_format: string;
  metadata: Record<string, unknown> | null;
  inserted_at: string;
  updated_at: string;
};

type ArtifactChannelPayload = {
  id: string;
  artifact_type: string;
  artifact_state: "draft" | "pending_approval" | "approved" | "applied" | "rejected";
  title: string | null;
  content: string | null;
  data: Record<string, unknown> | null;
  storage_ref: string | null;
  redaction_state: string | null;
  inserted_at: string;
  updated_at: string;
};

type ChatEventChannelPayload = {
  id: string;
  chat_run_id: string;
  chat_session_id: string | null;
  event_type: string;
  payload: Record<string, unknown> | null;
  inserted_at: string;
};

type ChatRunTaskChannelPayload = {
  id: string;
  chat_run_id: string;
  chat_session_id: string | null;
  task_id: string;
  source_message_id: string | null;
  source_artifact_id: string | null;
  relationship_kind: "created" | "updated" | "suggested" | "referenced";
  created_by: string | null;
  metadata: Record<string, unknown> | null;
  inserted_at: string;
  updated_at: string;
};
```

For the first implementation, project-level chat events are enough. A future
`chat_run:<chat_run_id>` channel can be added for very busy
projects, but it must preserve the same public payload shapes.

## Visibility Rules

### Public

Public GraphQL and channel payloads may include:

- Chat run id, title, status, active session summary, timestamps, and
  public metadata.
- Public chat messages.
- Public/redacted artifacts.
- Public progress events.
- Task links and the public task fields already exposed by `Task`.
- Public-safe outcome codes and identifiers.

### Internal or Operator-Only

These must not be exposed through public GraphQL, project channel events, or
user-visible artifacts:

- Raw system/developer prompts.
- Full model input/output traces that were not intentionally rendered as public
  assistant messages.
- Tool request/response bodies.
- Harness command logs, shell output, stack traces, workspace paths, and secrets.
- Runic/Jido graph provenance, compiled graph internals, node-level traces, and
  scheduler metadata.
- Internal scoring, ranking, or discarded task-generation candidates unless
  explicitly redacted into a public artifact.

Use `chat_events.internal_payload` or future operator-only trace storage for
that data. Public resolvers and channel serializers should have no code path
that copies internal payloads into public payloads.

## Task Creation and Origin Links

When a chat run creates tasks:

1. Insert the `Task` through the existing task creation path.
2. Insert a `chat_run_tasks` row in the same transaction.
3. Set `relationship_kind = "created"` for tasks born from the chat.
4. Include `chat_session_id`, `source_message_id`, and `source_artifact_id`
   when known.
5. Broadcast `task_created` and `chat_task_link_created` after commit.

Clients should render this in both directions:

- From the chat run: "Created tasks" section sourced from
  `ChatRun.createdTasks` or `ChatRun.taskLinks`.
- From task detail: "Origin chat run" sourced from `Task.chatOrigin`.

If a future chat run updates or references an existing task, add another
link row with `relationship_kind = "updated"` or `"referenced"`. Do not overwrite
the original `created` link.

## Future Migration Path

The MVP should use a native chat planning service with hardcoded orchestration:

```text
ChatRun
  -> ChatSession(session_kind: "planning", engine_kind: "native_planner")
      -> ChatMessage records
      -> public/internal ChatEvent records
      -> generic Artifact records through ArtifactLink
      -> Task + ChatRunTask links
```

If app-owned workflows, Jido, or Runic become necessary, migrate behind the chat
persistence contract:

1. Keep `ChatRun` as the public chat identity.
2. Keep public messages, artifacts, events, and task links unchanged.
3. Add or populate `chat_sessions.engine_kind`, `engine_session_ref`, and
   `definition_ref`.
4. Store graph/runtime provenance in internal-only event payloads or trace
   storage.
5. Introduce app-owned workflow definitions only after there are multiple chat
   flows that need user-editable definitions.
6. If a chat run creates executable tasks, those tasks may later receive
   ordinary workflows and `TaskRun`s, but that is downstream execution, not the
   chat run itself.

This keeps clients stable while allowing the backend implementation to move from
hardcoded planner logic to an app-owned graph runtime.

## Implementation Order

1. V0: add migrations, schemas, repository modules, account helpers, and tests
   for `chat_sessions`, `chat_messages`, and `chat_events` only.
2. Add GraphQL public types, queries, and mutations for the public V0 session
   transcript and event stream.
3. Add project channel broadcasts for public chat messages/events.
4. Add `chat_runs` when the product needs a stable conversation/work container
   above one or more sessions.
5. Add artifacts, artifact links, artifact decisions, task-origin links,
   archive/delete/history behavior, and task creation workflows after the
   session-first spine is stable.
6. Add optional `chat_investigation_requests` only when durable sub-work is
   needed.

## Acceptance Checks

The V0 persistence implementation should prove:

- A user can create a project-scoped `ChatSession` without creating a
  `ChatRun`, `TaskRun`, or `StepExecution`.
- The chat session lifecycle accepts only the V0 chat status values and stamps
  lifecycle timestamps for running, cancelling, and terminal states.
- A user can append public `ChatMessage` records to a session they own in the
  requested project.
- A user can append public and internal `ChatEvent` records to a session they
  own in the requested project.
- Public event helpers return only public events and never expose
  `internal_payload`.
- Cross-user or cross-project appends are rejected.

Later ChatRun/API implementations should also prove:

- A user can create a chat run and send messages.
- Public GraphQL never returns internal event payloads.
- Public channel events contain only public payload fields.
- A task created by a chat run is linked to the originating chat run in the same
  transaction.
- Approving and applying a `task_draft` artifact creates tasks through the chat
  planning service, not through a client-side backfill.
- `ChatRun.createdTasks` and `Task.chatOrigin` expose the relationship through
  GraphQL.
- Historical `TaskRun` and `StepExecution` behavior is unchanged.
