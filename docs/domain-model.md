# Domain Model

Sacrum is an API-only workflow engine and task management system built with Phoenix 1.8 (Elixir) and PostgreSQL. It provides the backend for defining multi-step workflows, managing tasks through those workflows, and tracking execution history — all over a **GraphQL API** with bearer token authentication and real-time WebSocket updates.

> **See also:** [Vertebrae Guide](vertebrae-guide.md) for the `vtb` CLI client that consumes this API.

## What It Does

**Workflow definition** — Users create projects containing workflows. Each workflow is an ordered sequence of steps connected by transitions, forming a directed graph. Workflows can also transition to other workflows, enabling multi-phase processes.

**Task management** — Tasks live inside projects and can be assigned to workflows. Once assigned, a task tracks its current step and can be moved along defined transitions. Tasks support:
- Parent-child hierarchies (tree decomposition)
- Dependency graphs with cycle detection and path finding (DAG)
- Structured sections (typed content blocks)
- Code references (file paths with line ranges)
- Tagging, priority, and level classification
- Human review flags with rejection/revision feedback

**Execution tracking** — Durable `TaskRun` records track automation lifecycle for a task run. `StepExecution` records track individual step attempts inside a run, including the step name, attempt status, and optional LLM metadata (model, provider, token counts, cost, duration). Session logs attach free-text content to executions.

**Chat runs contract** — Backend-owned chat work is modeled as user-facing runs that may span multiple chat sessions while researching, planning, and creating tasks. The V0 persistence slice is session-first and stores `ChatSession`, `ChatMessage`, and `ChatEvent` records before adding `ChatRun`, artifacts, or task-origin links. Chat persistence does not replace `TaskRun` or `StepExecution`. See [Chat Runs Contract](chat-runs.md).

**Real-time updates** — State changes broadcast to a Phoenix channel (`ProjectChannel`) keyed by project ID (`project:<project_id>`), so connected clients receive live events for task, workflow, and step mutations.

## Domain Model

```
User
 └── Project
      ├── Workflow
      │    ├── WorkflowStep ──→ StepTransition (step-to-step edges)
      │    └── WorkflowTransition (workflow-to-workflow edges)
      ├── Artifact (planned, generic)
      │    ├── ArtifactLink ──→ ChatRun / ChatSession / Task / TaskRun / StepExecution
      │    └── ArtifactDecision
      ├── ChatSession (V0 persisted)
      │    ├── ChatMessage
      │    └── ChatEvent
      ├── ChatRun (planned)
      │    └── ChatRunTask ──→ Task
      └── Task
           ├── TaskSection ──→ CodeRef
           ├── CodeRef (direct)
           ├── TaskHierarchy (parent ← child)
           ├── TaskDependency (task ← depends_on)
           └── TaskRun
                └── StepExecution
                     └── SessionLog
```

All entities use UUID primary keys and `utc_datetime_usec` timestamps.

## API Surface

The API is exposed via **GraphQL** at `/graphql` (GraphiQL playground available at `/graphiql` in development). All requests require bearer token auth (`Authorization: Bearer sac_...`).

**13 queries** across 5 type files, **36 mutations** across 7 type files.

### Queries

**`project_type.ex`** — Project queries
| Query | Arguments | Description |
|-------|-----------|-------------|
| `projects` | — | List all user's projects |
| `project` | `id!` | Single project by ID |

**`workflow_type.ex`** — Workflow queries
| Query | Arguments | Description |
|-------|-----------|-------------|
| `workflows` | `project_id!` | List workflows in a project |
| `workflow` | `id!` | Single workflow by ID |
| `pipelineSummary` | `project_id!` | Full workflow graph with per-step non-archived epic/ticket/task counts and active `TaskRun` counts |

**`workflow_step_type.ex`** — WorkflowStep queries
| Query | Arguments | Description |
|-------|-----------|-------------|
| `workflowSteps` | `workflow_id!` | List steps in a workflow |
| `workflowStep` | `id!` | Single step by ID |

**`task_type.ex`** — Task queries
| Query | Arguments | Description |
|-------|-----------|-------------|
| `tasks` | `project_id!`, `level`, `parent_id`, `status`, `tags`, `search`, `workflow_id`, `root_only`, `blocked` | List tasks with filters |
| `task` | `id!` | Single task by ID (accepts UUID or short_id) |
| `listReady` | `project_id!` | Tasks with no incomplete blockers |
| `findPath` | `from_id!`, `to_id!` | Shortest dependency path between tasks |

**`execution_types.ex`** — Execution queries
| Query | Arguments | Description |
|-------|-----------|-------------|
| `activeRun` | `task_id!` | Current active `TaskRun` for a task, or null |
| `taskRuns` | `task_id!` | List durable runs for a task |
| `taskRun` | `id!` | Single durable run by ID |
| `taskRunTrace` | `root_task_run_id!` | Full run trace with child runs, step attempts, and logs |
| `stepExecutions` | `task_id!` | List executions for a task |
| `stepExecution` | `id!` | Single execution by ID |
| `sessionLogs` | `step_execution_id!` | List logs for an execution |

### Mutations

**`project_type.ex`** — 3 mutations (all via `Accounts.Projects`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createProject` | `name!`, `description`, `slug` | `:project` |
| `updateProject` | `id!`, `name`, `description`, `slug` | `:project` |
| `deleteProject` | `id!` | `:project` |

**`workflow_type.ex`** — 4 mutations (all via `Accounts.Workflows`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createWorkflow` | `project_id!`, `name!`, `description`, `metadata`, `auto_advance`, `display_order`, `is_default` | `:workflow` |
| `updateWorkflow` | `id!`, `name`, `description`, `metadata`, `auto_advance`, `display_order`, `is_default`, `initial_step_id` | `:workflow` |
| `deleteWorkflow` | `id!` | `:workflow` |
| `syncWorkflowTransitions` | `id!`, `transitions!` (list of `WorkflowTransitionInput`) | `:workflow` |

**`workflow_step_type.ex`** — 4 mutations (all via `Accounts.WorkflowSteps`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createWorkflowStep` | `workflow_id!`, `name!`, `goal`, `agents`, `skills`, `agent_config`, `is_final`, `step_order` | `:workflow_step` |
| `updateWorkflowStep` | `id!`, `name`, `goal`, `agents`, `skills`, `agent_config`, `is_final`, `step_order` | `:workflow_step` |
| `deleteWorkflowStep` | `id!` | `:workflow_step` |
| `syncStepTransitions` | `id!`, `transitions!` (list of `StepTransitionInput`) | `:workflow_step` |

**`task_type.ex`** — 11 mutations (CRUD via `Accounts.Tasks`, workflow ops via `Repo.TaskWorkflows`, deps via `Repo.TaskDependencies`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createTask` | `project_id!`, `title!`, `description`, `level`, `priority`, `tags`, `parent_id`, `sections` | `:task` |
| `updateTask` | `id!`, `title`, `description`, `level`, `priority`, `tags`, `needs_human_review`, `review_comment`, `rejection_reason`, `revision_feedback`, `started_at`, `completed_at`, `parent_id`, `depends_on_ids`, `sections` | `:task` |
| `deleteTask` | `id!`, `cascade` (default: true) | `:task` |
| `createTaskDependency` | `task_id!`, `depends_on_id!` | `:task` |
| `deleteTaskDependency` | `task_id!`, `depends_on_id!` | `:task` |
| `assignWorkflow` | `task_id!`, `workflow_id!` | `:task` |
| `unassignWorkflow` | `task_id!` | `:task` |
| `moveToStep` | `task_id!`, `step_id!` | `:task` |
| `startStep` | `task_id!` | `:task` |
| `completeStep` | `task_id!` | `:task` |
| `rejectStep` | `task_id!`, `target_step_id!`, `feedback` | `:task` |

**`section_types.ex`** — 5 mutations (all via `Accounts.Sections` / `Accounts.CodeRefs`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createSection` | `task_id!`, `section_type!`, `content!`, `section_order`, `done` | `:task_section` |
| `updateSection` | `id!`, `section_type`, `content`, `section_order`, `done`, `done_at` | `:task_section` |
| `deleteSection` | `id!` | `:task_section` |
| `createCodeRef` | `task_id` or `section_id`, `path!`, `line_start`, `line_end`, `name`, `description` | `:code_ref` |
| `deleteCodeRef` | `id!` | `:code_ref` |

**`transition_types.ex`** — 4 mutations (via `Accounts.WorkflowTransitions` / `Accounts.StepTransitions`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createWorkflowTransition` | `from_workflow_id!`, `to_workflow_id!`, `label`, `target_step_id` | `:workflow_transition` |
| `deleteWorkflowTransition` | `id!` | `:workflow_transition` |
| `createStepTransition` | `from_step_id!`, `to_step_id!`, `label` | `:step_transition` |
| `deleteStepTransition` | `id!` | `:step_transition` |

**`execution_types.ex`** — 5 mutations (via `Accounts.StepExecutions` / `Accounts.SessionLogs`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createStepExecution` | `task_id!`, `workflow_id!`, `step_name!`, `status`, `context`, `prompt`, `output`, `transition_result`, `model`, `model_provider`, `input_tokens`, `output_tokens`, `session_input_tokens`, `session_cache_read_input_tokens`, `session_output_tokens`, `session_total_tokens`, `context_window_input_tokens`, `context_window_cache_read_input_tokens`, `context_window_total_tokens`, `cost`, `duration_ms` | `:step_execution` |
| `updateStepExecution` | `id!`, `step_name`, `status`, `context`, `prompt`, `output`, `transition_result`, `model`, `model_provider`, `input_tokens`, `output_tokens`, `session_input_tokens`, `session_cache_read_input_tokens`, `session_output_tokens`, `session_total_tokens`, `context_window_input_tokens`, `context_window_cache_read_input_tokens`, `context_window_total_tokens`, `cost`, `duration_ms` | `:step_execution` |
| `createSessionLog` | `step_execution_id!`, `content!`, `format` (`anthropic` default, or `openai`) | `:session_log` |
| `runStep` | `task_id!`, `workflow_id!`, `step_id!` | `:step_execution` |
| `cancelStepExecution` | `step_execution_id!` | `:step_execution` |

> **Implementation:** See `lib/sacrum_web/graphql/schema.ex` for the root schema and `lib/sacrum_web/graphql/types/*.ex` for type definitions. `!` denotes required arguments.

## Tech Stack

| Layer | Technology |
|---|---|
| Language | Elixir ~> 1.15 |
| Framework | Phoenix 1.8 |
| Database | PostgreSQL via Ecto 3.13 |
| HTTP Server | Bandit |
| Auth | Bearer tokens (SHA256 stored, Argon2 passwords) |
| HTTP Client | Req |
| Real-time | Phoenix Channels (PubSub) |
| API | GraphQL (Absinthe) |

## Real-Time Events

Connect to `project:<project_id>` via WebSocket to receive real-time updates. The channel supports two client types:

- **default** — Receives all entity change events (UI clients)
- **daemon** — Receives only `run_step` and `cancel_step` commands (worker processes)

The complete default-client WalEx CDC mapping, source-row requirements, payload
completeness guarantees, daemon command exclusions, and snapshot/gap recovery
rules are defined in
[WalEx CDC GUI Projection Contract](walex-cdc-gui-projection-contract.md).

### Event Types

| Event | Payload | Description |
|-------|---------|-------------|
| `task_created` / `task_updated` / `task_deleted` | Task fields (including `schema_version` and `archived`; delete includes before-image position fields) | Task lifecycle changes |
| `task_parent_changed` | `{schema_version, task_id, project_id, from_parent_id, to_parent_id, level}` | Explicit task hierarchy move for tree UIs |
| `task_dependency_created` / `task_dependency_deleted` | Dependency edge fields: `id`, `task_id`, `depends_on_id`, `project_id`, timestamps | Blocker/dependency relation changes |
| `workflow_created` / `workflow_updated` / `workflow_deleted` | Workflow fields | Workflow lifecycle |
| `step_created` / `step_updated` / `step_deleted` | Step fields | WorkflowStep lifecycle |
| `step_transition_created` / `step_transition_deleted` | Transition fields | Step-to-step edges |
| `step_execution_created` | Execution fields | New execution started |
| `step_execution_status_changed` | Execution fields | Status update (entered, completed, etc.) |
| `task_run_created` / `task_run_updated` | TaskRun fields | TaskRun lifecycle changes |
| `task_run_step_changed` | `{schema_version, task_run_id, task_id, from_step_id, to_step_id, status, level}` | Emitted at root or child run start, whenever a task's `current_step_id` changes while a TaskRun exists, and at run-end paths (`to_step_id` is `nil`). Lets pipeline views decrement the source step bucket and increment the destination bucket without refetching. |
| `task_step_changed` | `{schema_version, task_id, from_step_id, to_step_id, workflow_id, level}` | Emitted when `current_step_id` changes outside orchestrator execution (`assign_workflow`, `advance_to_step`, `move_to_step`). Mirrors `task_run_step_changed` for the manual-move case where no TaskRun exists; only fires when `from != to`. |
| `session_log_created` | Log fields | New log entry attached |
| `section_created` / `section_updated` / `section_deleted` | Section fields | Task section changes |
| `code_ref_created` / `code_ref_updated` / `code_ref_deleted` | Code reference fields: task/section owner, path, line range, name, description, timestamps | Task detail and evidence reference changes |
| `chat_session_created` / `chat_session_updated` / `chat_message_created` / `chat_event_created` | Public payloads projected from public `chat_events` rows | Public live-chat transcript and progress events; internal events are suppressed |
| `run_step` | Execution + step config | **Daemon only** — Run a step |
| `cancel_step` | Execution ID, task ID | **Daemon only** — Cancel running step |

> **Implementation:** See `Sacrum.Realtime.Cdc.Projector`, `SacrumWeb.ProjectChannel`, and `Sacrum.Realtime.CommandBroadcaster` for daemon-only commands.

## Architecture Pattern

The codebase uses a **three-layer architecture** (Accounts → Repo → Ecto) instead of Phoenix contexts. See [Repository & Accounts Pattern](patterns.md) for the full reference, including GenericRepo, GenericResource, and Accounts layer documentation.

| Entity | Schema | Repository | Accounts | GraphQL Type |
|--------|--------|------------|----------|--------------|
| Task | `Schemas.Task` | `Repo.Tasks` | `Accounts.Tasks` | `task_type.ex` |
| Workflow | `Schemas.Workflow` | `Repo.Workflows` | `Accounts.Workflows` | `workflow_type.ex` |
| WorkflowStep | `Schemas.WorkflowStep` | `Repo.WorkflowSteps` | `Accounts.WorkflowSteps` | `workflow_step_type.ex` |
| Section | `Schemas.TaskSection` | `Repo.TaskSections` | `Accounts.Sections` | `section_types.ex` |
| StepExecution | `Schemas.StepExecution` | `Repo.StepExecutions` | `Accounts.StepExecutions` | `execution_types.ex` |
| TaskRun | `Schemas.TaskRun` | `Repo.TaskRuns` | `Accounts.TaskRuns` | `execution_types.ex` |
| Project | `Schemas.Project` | `Repo.Projects` | `Accounts.Projects` | `project_type.ex` |

Complex operations (transition syncing, workflow assignment, step movement) use `Ecto.Multi` for transactional safety. Dependency management includes BFS shortest-path and DFS cycle-detection algorithms.

## Status and Run State

Sacrum has separate status fields for separate questions. Do not collapse them into one source of truth.

| Field | Answers | Source of Truth |
|-------|---------|-----------------|
| `Task.status` | Compatibility queue summary for task lists and filters | Derived durable task state |
| `TaskRun.status` | What is the automation run doing now? | Durable run lifecycle |
| `StepExecution.status` | What happened to one step attempt? | Daemon/orchestrator attempt updates |
| `SessionLog` | What text/content was emitted during an attempt? | Append-only log content, no lifecycle status |
| `ChatRun.status` (planned) | What is happening in a user-facing chat run? | Durable chat run lifecycle, separate from task automation |
| `ChatSession.status` (planned) | What happened during one chat session attempt? | Chat session attempt state, separate from `StepExecution` |

Use `Task.status` only as a compatibility list/filter field for queue states that Sacrum still persists on `tasks`. New derivations write `ready` or `done`; historical `running` and `waiting` values remain valid database/filter values until clients finish migrating. Use `TaskRun.status` for automation controls such as whether a run is active or stoppable. Use `Task.workflow` and `Task.current_step` for workflow position. Use `StepExecution.status` for attempt history, retry diagnostics, and LLM metadata. `SessionLog` has no state/status field; it records content attached to a `StepExecution` and must not be used to infer run state.

Chat runs answer a different question: what happened in a user-facing conversation/work container that can span multiple chat sessions and produce zero, one, or many tasks. A `ChatRun` may create tasks, artifacts, and public chat messages, but it must not be treated as a `TaskRun` unless a created task later enters normal workflow execution. `ChatSession` is the chat-side execution-attempt layer, closer to `StepExecution` than to `TaskRun`.

### Task.status

Task status is derived by `Sacrum.Tasks.Status.derive/1` and persisted into the `tasks.status` column. The field remains in GraphQL and repository filters for compatibility, but it is no longer the source of truth for active automation lifecycle. Read paths (GraphQL, queries, filters) read the column directly.

Derivation rules are evaluated in order; the first match wins.

- **`:done`** — Task completion has been stamped (`completed_at` is set).
- **`:ready`** — The task is not completed.

`Status.derive/1` does not inspect `StepExecution.status` for active states. A latest attempt with `"started"`, `"in_progress"`, `"waiting"`, `"cancelling"`, or `"failed"` does not make the task `running`, `waiting`, or failed. Those are run/attempt questions owned by `TaskRun.status` and `StepExecution.status`.

The `tasks.status` database constraint still accepts `ready`, `running`, `waiting`, and `done` so older clients can continue filtering legacy rows. New refreshes only write `ready` or `done`. Clients that currently use `tasks(status: "running")` or `tasks(status: "waiting")` should migrate to `activeRun`, `taskRuns`, or `runControls.activeRun.status` for run lifecycle and to `workflow`/`currentStep` for workflow position.

Task dependencies (blockers) are *not* part of status derivation. Blockers are an informational relationship; they do not move a task into `:waiting`. Read paths that need "actionable now" (e.g. `listReady`) filter dependents in the query layer, not via status.

### TaskRun.status

`TaskRun.status` is the canonical automation lifecycle for a durable run. The reusable contract lives in `Sacrum.TaskRuns.Status`.

Canonical values:

- **`:queued`** — Run exists and is waiting to be picked up or resumed.
- **`:executing`** — The run is actively executing a step attempt.
- **`:waiting`** — The run is active but blocked on child runs or another orchestrated wait.
- **`:stopping`** — Stop has been requested and shutdown/cancellation is in progress.
- **`:stopped`** — The run stopped before successful completion.
- **`:completed`** — The run reached its successful outcome.
- **`:failed`** — The run exhausted retry/recovery policy or hit a permanent run failure.

Predicate semantics:

- `active?` is true for `:queued`, `:executing`, `:waiting`, and `:stopping`.
- `terminal?` is true for `:stopped`, `:completed`, and `:failed`.
- `successful?` is true only for `:completed`.
- `failed?` is true only for `:failed`.
- `stoppable?` is true for `:queued`, `:executing`, and `:waiting`; `:stopping` is still active but stop has already been requested.

`StepExecution.status == "failed"` does not by itself mean the `TaskRun` failed. A failed step attempt can be retried while the enclosing `TaskRun.status` remains `:queued`, `:executing`, or `:waiting`. Set `TaskRun.status` to `:failed` only when retry/recovery is exhausted or the run has a permanent failure.

Pipeline summaries follow the same boundary. `pipelineSummary.workflowSteps.activeCount`
and `pipelineSummary.workflowSteps.pipelineCounts.active` count active
`TaskRun.status` values (`queued`, `executing`, `waiting`, `stopping`) for
non-archived tasks at the step. `runningCount` is retained as a compatibility
alias for this active count and must not be derived from `StepExecution.status`.

Pipeline views can stay in sync incrementally from the event stream alone.
The relevant signals are:

- `task_created` / `task_updated` / `task_deleted` — track which step a task
  lives at and whether it is archived. The `task_updated` payload includes
  `archived`, so archive/unarchive flips immediately move the task in or out of
  pipeline buckets without a refetch. The `task_deleted` payload includes
  before-image `current_step_id`, `workflow_id`, `level`, and `archived`, so
  deletes can decrement pipeline buckets without a client-side position cache.
- `task_run_created` and `task_run_updated` — track run-level status for the
  active bucket.
- `task_run_step_changed` — a dedicated event emitted at root or child run
  start, whenever a task's `current_step_id` changes while a TaskRun exists, and
  at run-end paths (completion, retry exhaustion, stop). At run start it follows
  `task_run_created` and precedes the first `task_run_updated`, with
  `from_step_id: nil` and `to_step_id` set to the current task step. The payload
  is `{schema_version, task_run_id, task_id, from_step_id, to_step_id, status, level}`
  and carries the wire status from `Sacrum.TaskRuns.Status.wire_value/1`.
  `to_step_id` is `nil` at run-end paths so clients can decrement the active
  bucket of the run's last step.
- `task_step_changed` — the parallel signal for manual moves outside the
  orchestrator (`Repo.TaskWorkflows.assign_workflow/2`, `advance_to_step/2`,
  `move_to_step/2`). Payload is
  `{schema_version, task_id, from_step_id, to_step_id, workflow_id, level}`. No `task_run_id`
  or `status` because manual moves block when an orchestrator is active, so no
  TaskRun exists. Only fires when `from != to`.

Not every step transition dispatches a new `step_execution_created`, so
`step_execution_created` is **not** a reliable from/to signal for pipeline
counts. Use `task_run_step_changed` (orchestrator path) and
`task_step_changed` (manual path) instead.

### Waiting on Children

A parent run that dispatches child task runs and then waits for them maps to `TaskRun.status == :waiting`. This status is active and stoppable: the run still owns automation work even though it is not currently executing a daemon step.

The current wait step may also have `StepExecution.status == "waiting"`, but that is attempt-level state. The parent run leaves `:waiting` when the orchestrator resumes after children complete, when stop succeeds, or when the run fails.

### Child Run Lineage

Manual runs default to a new root `TaskRun`. Do not attach a manually started run to an existing parent just because the task has a parent task or dependency relationship.

Server-side orchestration may create a child run by supplying a validated `parent_task_run_id` and the matching `root_task_run_id`/`triggered_by_step_execution_id`. If the parent run is missing, out of scope, or not created by orchestration, reject the lineage instead of inferring it from task hierarchy. GUI and CLI callers should not propagate child-run lineage directly.

### StepExecution.status

`StepExecution.status` is attempt-level state. It can record values such as `"started"`, `"in_progress"`, `"waiting"`, `"completed"`, `"failed"`, `"cancelled"`, or `"invalidated"` for a single attempt. Use it for historical execution rows, retry counts, handoff payloads, prompts, output, and telemetry.

Never derive permanent task or run failure from the latest `StepExecution.status` alone. Retry gaps, cancellations, waiting states, and orchestrator crashes make that ambiguous; `TaskRun.status` is the durable run-level answer.

### SessionLog

`SessionLog` entries are content records attached to a `StepExecution`. They do not have state or status, and they should not drive task status, run status, retry policy, or active-run detection.

### Timestamp Stamping Invariants

Task lifecycle timestamps are stamped by the workflow/run state transitions that
own the relevant lifecycle boundary.

**`started_at`** — Stamped in `ExecutionDispatcher.create_and_dispatch/4` when the task first dispatches (if currently nil).
- Idempotent: subsequent dispatches do not re-stamp; the timestamp persists for the task's lifetime
- Represents the first moment the orchestrator began work on the task

**`completed_at`** — Stamped when the task enters a terminal step in a terminal workflow (if currently nil). This happens through `TaskCompletion.handle_completion/1` for orchestrated runs, and through `TaskWorkflows.assign_workflow/2`, `advance_to_step/2`, or `move_to_step/2` for manual workflow assignment/movement into a terminal position.
- Idempotent: retries or repeated completions do not re-stamp
- Represents the task's transition to the :done state

### Refresh Points

Operations that change derivation inputs run the position update and the status refresh in the same `Ecto.Multi`/transaction, using `Status.changeset/1` as the second step:

- `TaskWorkflows.assign_workflow / unassign_workflow / advance_to_step / move_to_step` — wraps the position update, terminal-position `completed_at` stamping, and compatibility status refresh in one transaction; broadcasts after commit
- `TaskCompletion.handle_completion/1` — wraps `completed_at` stamping and status refresh in one transaction
- `ExecutionDispatcher.create_and_dispatch/4` — stamps `started_at` without deriving an active task status from the started attempt

`TaskDependencies.add_dependency / remove_dependency` do not refresh status — dependencies are not derivation inputs.

### Example

```elixir
status = Sacrum.Tasks.Status.derive(task)  # => :ready | :done
active = Sacrum.TaskRuns.Status.active?(task_run.status)
```
