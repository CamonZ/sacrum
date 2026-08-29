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
- Workflow-step based human review via `current_step_id` and `WorkflowStep.step_type == "human_input"`
- Repeatable workflow runs via `WorkflowStep.step_type == "stop"`, which ends
  the current TaskRun at a run boundary without completing the task

**Execution tracking** — Durable `TaskRun` records track automation lifecycle for a task run. `StepExecution` records track individual step attempts inside a run, including the step name, attempt status, and optional LLM metadata (model, provider, token counts, cost, duration). Session logs attach free-text content to executions.

**Artifact files** — Projects contain named text files whose contents are stored in `Artifact.body`. `ArtifactLink` records attach those files to projects, tasks, task sections, workflows, task runs, and step executions.

**Real-time updates** — State changes broadcast to a Phoenix channel (`ProjectChannel`) keyed by project ID (`project:<project_id>`), so connected clients receive live events for task, workflow, and step mutations.

## Domain Model

```
User
 └── Project
      ├── Workflow
      │    ├── WorkflowStep ──→ StepTransition (step-to-step edges)
      │    └── WorkflowTransition (workflow-to-workflow edges)
      ├── Artifact (filename + body)
      │    └── ArtifactLink ──→ Project / Task / TaskSection / Workflow /
      │                         TaskRun / StepExecution
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

### Artifacts

An artifact is a project-scoped text file with two content fields:

- `filename` — the physical/client-facing file name, including the extension used by clients to interpret the contents
- `body` — the complete file contents stored as a string

For example, Markdown is stored as a `.md` filename and Markdown body, while JSON is stored as a `.json` filename and JSON text body. Sacrum preserves the string exactly; it does not parse the body or maintain a separate structured-data payload. File interpretation is extension-based and belongs to the client.

Every artifact row has `user_id` and `project_id` ownership scope. Attachments are represented separately by `ArtifactLink`. Each link may carry a nullable `logical_name`: a stable role/tag for that subject attachment. Logical names are unique within a user, project, subject type, and subject ID, but can be reused on other subjects; existing unnamed links remain valid. A project attachment uses `subject_type: "project"` and the owning project ID as `subject_id`. The project scope on the artifact row does not by itself make the file appear in `Project.artifacts`; that GraphQL field returns files with a matching project subject link.

`ArtifactLink.metadata` is an embedded, versioned schema. When metadata is supplied, it must use this JSON envelope:

```json
{
  "version": 1,
  "content_kind": "conversation",
  "format": "jsonl",
  "origin": "harness",
  "presentation": "raw",
  "extensions": {
    "harness": {"conversation_id": "..."}
  }
}
```

All six keys are required and `version` must be `1`; `extensions` must be an object and is preserved without provider-specific validation. Other metadata shapes are rejected. `origin` and `presentation` are non-empty strings, so unfamiliar providers and presentation modes remain valid. Clients should use `presentation` when they recognize it; otherwise, they should infer a generic raw view from `format`, then the filename extension (for example, `.jsonl`), and finally render the unmodified body as text. Sacrum does not parse artifact bodies or implement provider-specific conversation renderers.

The Accounts subject-listing and link-creation paths include both the caller's user ID and project ID. Subject reads additionally match `subject_type` and `subject_id`, so those application paths do not return links or files across user or project boundaries. Artifact creation plus its initial link is transactional through `Accounts.Artifacts.create_and_link/4`. Updating an artifact can replace its sole attachment within the same ownership scope; file and link changes commit or roll back together. Deleting an artifact cascades to its links.

Orchestration prompt rendering exposes artifact identities without artifact bodies. `artifacts["project"]`, `artifacts["task"]`, and `artifacts["task_run"]` map logical names to `%{"id" => artifact_id}` values. For preceding persisted executions in the current TaskRun, `artifacts["step_execution"]["history"]` is a zero-based array aligned with `execution.history`: index `0` is the immediately preceding execution, and farther indexes move backward through deterministic `inserted_at`/`id` order. Entries without named links are empty maps, retries remain separate entries, and the current execution being rendered is not included.

## API Surface

The API is exposed via **GraphQL** at `/graphql` (GraphiQL playground available at `/graphiql` in development). All requests require bearer token auth (`Authorization: Bearer sac_...`).

Queries and mutations are grouped by resource in `lib/sacrum_web/graphql/types/`.

### Queries

**`project_type.ex`** — Project queries
| Query | Arguments | Description |
|-------|-----------|-------------|
| `projects` | — | List all user's projects |
| `project` | `id!` | Single project by ID |

The `Project.artifacts(limit: 50, offset: 0)` field returns the caller's project-linked artifacts newest first. `limit` is clamped to `1..50`, and `offset` is clamped to zero or greater for offset-based pagination. Each attachment-context artifact exposes `id`, `filename`, `body`, `logicalName`, `metadata`, `insertedAt`, and `updatedAt`. Linked files are also exposed on `Task.artifacts`, `TaskSection.artifacts`, and `TaskSection.evidence`.

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
| `task` | `id!` | Single task by canonical UUID |
| `listReady` | `project_id!` | Tasks with no incomplete blockers |
| `findPath` | `from_id!`, `to_id!` | Shortest dependency path between tasks |

**`artifact_types.ex`** — Artifact queries
| Query | Arguments | Description |
|-------|-----------|-------------|
| `artifact` | `id!` | Read one artifact by UUID in the authenticated user's ownership scope |

`artifact(id: UUID4!)` returns `id`, `filename`, `body`, `logicalName`, `metadata`, `insertedAt`, and `updatedAt`. Link fields are populated for create/update results and subject attachment reads; the root `artifact` lookup returns them as `null` because an artifact can have multiple attachments. `artifactByLogicalName(projectId:, subjectType:, subjectId:, logicalName:)` resolves one artifact inside the authenticated user's user/project/subject scope, making it suitable for CLI and orchestrator clients. The resolver uses `Accounts.Artifacts.get/2`, so missing or unauthorized artifacts return the same GraphQL not-found error as artifact mutations; malformed IDs are rejected by the `UUID4` scalar before the resolver runs.

**`execution_types.ex`** — Execution queries
| Query | Arguments | Description |
|-------|-----------|-------------|
| `activeRun` | `task_id!` | Current active `TaskRun` for a task, or null |
| `taskRuns` | `task_id!` | List durable runs for a task |
| `taskRun` | `id!` | Single durable run by ID |
| `taskRunTrace` | `root_task_run_id!` | Single requested `TaskRun` with directly attached step attempts and logs |
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

**`artifact_types.ex`** — 3 mutations (via `Accounts.Artifacts`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createArtifact` | `project_id!`, `filename!`, `body!`, `subject_type`, `subject_id`, `logical_name`, `metadata` | `:artifact` |
| `updateArtifact` | `id!`, `filename`, `body`, `subject_type`, `subject_id`, `logical_name`, `metadata` | `:artifact` |
| `deleteArtifact` | `id!` | `:artifact` |

`createArtifact` creates the file in the authenticated user's project and atomically attaches it to a subject. `logicalName` and `metadata` belong to that link, not the artifact file. When `subject_type` and `subject_id` are omitted, the link targets the project for backward compatibility; when supplied together, the destination may be a project, task, task section, workflow, task run, or step execution in the same user and project scope. Requests for a project or destination outside the caller's scope fail without persisting either row.

`updateArtifact` changes `filename`, `body`, or both. Supplying `subject_type` and `subject_id` together replaces the artifact's sole link while preserving its metadata and logical name unless replacement values are supplied. Supplying only `logicalName` or `metadata` updates the sole link. The target must belong to the artifact's existing user and project; ownership and project scope never move. Invalid targets, metadata, or duplicate names roll back file edits and leave the original link intact. Artifacts with multiple links can still update file fields, but attachment replacement or link-field updates are rejected as ambiguous.

`deleteArtifact` deletes an artifact owned by the authenticated user and returns the deleted file. Its `ArtifactLink` rows are removed by the database cascade. Update and delete requests for another user's artifact return not found.

**`workflow_type.ex`** — 4 mutations (all via `Accounts.Workflows`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createWorkflow` | `project_id!`, `name!`, `description`, `metadata`, `display_order`, `is_default` | `:workflow` |
| `updateWorkflow` | `id!`, `name`, `description`, `metadata`, `display_order`, `is_default`, `initial_step_id` | `:workflow` |
| `deleteWorkflow` | `id!` | `:workflow` |
| `syncWorkflowTransitions` | `id!`, `transitions!` (list of `WorkflowTransitionInput`) | `:workflow` |

**`workflow_step_type.ex`** — 4 mutations (all via `Accounts.WorkflowSteps`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createWorkflowStep` | `workflow_id!`, `name!`, `goal`, `agents`, `skills`, `agent_config`, `step_order`, `prompt`, `output_schema`, `persistence_options`, `route_config` | `:workflow_step` |
| `updateWorkflowStep` | `id!`, `name`, `goal`, `agents`, `skills`, `agent_config`, `step_order`, `prompt`, `output_schema`, `persistence_options`, `route_config` | `:workflow_step` |
| `deleteWorkflowStep` | `id!` | `:workflow_step` |
| `syncStepTransitions` | `id!`, `transitions!` (list of `StepTransitionInput`) | `:workflow_step` |

**`task_type.ex`** — 11 mutations (CRUD via `Accounts.Tasks`, workflow ops via `Repo.TaskWorkflows`, deps via `Repo.TaskDependencies`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `createTask` | `project_id!`, `title!`, `description`, `level`, `priority`, `tags`, `parent_id`, `sections` | `:task` |
| `updateTask` | `id!`, `title`, `description`, `level`, `priority`, `tags`, `rejection_reason`, `started_at`, `completed_at`, `parent_id`, `depends_on_ids`, `sections` | `:task` |
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

**`execution_types.ex`** — 4 mutations (via `Accounts.StepExecutions` / `Accounts.SessionLogs`)
| Mutation | Arguments | Returns |
|----------|-----------|---------|
| `updateStepExecution` | `id!`, `step_name`, `status`, `context`, `prompt`, `output`, `transition_result`, `model`, `model_provider`, `input_tokens`, `output_tokens`, `session_input_tokens`, `session_cache_read_input_tokens`, `session_output_tokens`, `session_total_tokens`, `context_window_input_tokens`, `context_window_cache_read_input_tokens`, `context_window_total_tokens`, `cost`, `duration_ms` | `:step_execution` |
| `createSessionLog` | `step_execution_id!`, `content!`, `format` (`anthropic` default, or `openai`), optional opaque `logical_key` for in-place updates | `:session_log` |
| `runStep` | `task_id!`, `workflow_id!`, `step_id!` | `:step_execution` |
| `cancelStepExecution` | `step_execution_id!` | `:step_execution` |

> **Implementation:** See `lib/sacrum_web/graphql/schema.ex` for the root schema and `lib/sacrum_web/graphql/types/*.ex` for type definitions. `!` denotes required arguments.

`WorkflowStep.routeConfig` is inert, versioned JSON validated by the existing
workflow-step changeset and route graph write path. Its presence selects
deterministic routing; `prompt` remains an independent nullable fallback and is
used only when `routeConfig` is absent. On updates, omitted fields are left
unchanged, while `prompt: null`, `prompt: ""`, and a non-null prompt are distinct
wire values. `routeConfig: null` explicitly clears the configuration.

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
| `session_log_created` | Log fields, including nullable `logical_key` | New log entry attached |
| `session_log_updated` | Log fields, including nullable `logical_key` | Existing logical-key log row updated in place |
| `section_created` / `section_updated` / `section_deleted` | Section fields | Task section changes |
| `code_ref_created` / `code_ref_updated` / `code_ref_deleted` | Code reference fields: task/section owner, path, line range, name, description, timestamps | Task detail and evidence reference changes |
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
| Artifact | `Schemas.Artifact` | `Repo.Artifacts` | `Accounts.Artifacts` | `artifact_types.ex` |
| ArtifactLink | `Schemas.ArtifactLink` | `Repo.ArtifactLinks` | `Accounts.Artifacts` | No standalone type; exposed through artifact fields on Project, Task, and TaskSection |

Complex operations (transition syncing, workflow assignment, step movement) use `Ecto.Multi` for transactional safety. Dependency management includes BFS shortest-path and DFS cycle-detection algorithms.

## Status and Run State

Sacrum has separate status fields for separate questions. Do not collapse them into one source of truth.

| Field | Answers | Source of Truth |
|-------|---------|-----------------|
| `Task.status` | Compatibility queue summary for task lists and filters | Derived durable task state |
| `TaskRun.status` | What is the automation run doing now? | Durable run lifecycle |
| `StepExecution.status` | What happened to one step attempt? | Daemon/orchestrator attempt updates |
| `SessionLog` | What text/content was emitted during an attempt? | Append-only log content, no lifecycle status |

Use `Task.status` only as a compatibility list/filter field for queue states that Sacrum still persists on `tasks`. New derivations write `ready` or `done`; historical `running` and `waiting` values remain valid database/filter values until clients finish migrating. Use `TaskRun.status` for automation controls such as whether a run is active or stoppable. Use `Task.workflow` and `Task.current_step` for workflow position. Use `StepExecution.status` for attempt history, retry diagnostics, and LLM metadata. `SessionLog` has no state/status field; it records content attached to a `StepExecution` and must not be used to infer run state.

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

A stop step is an orchestrator-owned run boundary. When a workflow reaches it,
the current TaskRun becomes `:stopped` with `outcome_kind == "run_boundary"`
and an `outcome_context` containing `reason: "stop_step"` and the boundary
step ID. The task remains incomplete and its `current_step_id` remains on the
stop step. The next `runWorkflow` invocation creates a distinct TaskRun,
advances past the stop step, and dispatches the next executable step. It does
not resume or mutate the historical stopped run. Stop steps are never sent to
the daemon as `run_step` commands.

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

At a run boundary, clients should use the terminal `task_run_updated` payload
and its `outcome_kind`/`outcome_context` to distinguish a deliberate boundary
from an operator stop. The following TaskRun has its own lifecycle and is the
source of active controls after it is created.

### Waiting on Children

A parent run that dispatches child task runs and then waits for them maps to `TaskRun.status == :waiting`. This status is active and stoppable: the run still owns automation work even though it is not currently executing a daemon step.

The current wait step may also have `StepExecution.status == "waiting"`, but that is attempt-level state. The parent run leaves `:waiting` when the orchestrator resumes after children complete, when stop succeeds, or when the run fails.

### Child Run Lineage

Manual runs default to a new root `TaskRun`. Do not attach a manually started run to an existing parent just because the task has a parent task or dependency relationship.

Server-side orchestration may create a child run by supplying a validated `parent_task_run_id` and the matching `root_task_run_id`/`triggered_by_step_execution_id`. If the parent run is missing, out of scope, or not created by orchestration, reject the lineage instead of inferring it from task hierarchy. GUI and CLI callers should not propagate child-run lineage directly.

### TaskRun Concurrency

An optional positive `TaskRun.max_concurrency` is stored only on a root run.
The root run and every descendant share one execution-pool scope identified by
the root run ID. For a descendant, `root_task_run_id` points to the original
root even when `parent_task_run_id` points to an intermediate run; there is no
separate per-parent budget.

The execution pool admits work only when both the global pool and the root
scope have capacity. A missing or `NULL` root limit preserves the legacy
global-only behavior. The root limit is selected at root-run creation and is
immutable for the active run; reusing an active run does not replace it.

The GraphQL `TaskRun.maxConcurrency` field exposes the effective root limit,
including for descendants. `runWorkflow(maxConcurrency: ...)` is the client
entry point for selecting the limit. Direct `runStep` dispatch cannot be used
to bypass a custom root limit and is rejected for such a run; unlimited runs
continue to use the existing global-only path.

### StepExecution.status

`StepExecution.status` is attempt-level state. It can record values such as `"started"`, `"in_progress"`, `"waiting"`, `"completed"`, `"failed"`, `"cancelled"`, or `"invalidated"` for a single attempt. Use it for historical execution rows, retry counts, handoff payloads, prompts, output, and telemetry.

Never derive permanent task or run failure from the latest `StepExecution.status` alone. Retry gaps, cancellations, waiting states, and orchestrator crashes make that ambiguous; `TaskRun.status` is the durable run-level answer.

### Deterministic route provenance

A completed local deterministic route keeps its canonical audit in
`StepExecution.context.route`. The record contains `mode`,
`source_execution_id`, `config_version`, `matched_rule_id`, `used_default`, and
the evaluated `context` snapshot. The destination remains the JSON string in
`transition_result` (`dest_id` and `transition_type`), and the carried payload
remains `handoff`.

GraphQL exposes these existing fields as `context`, `transitionResult`, and
`handoff`; the channel sends the same values as snake_case keys. `output` is not
an audit document and must not be used for route provenance. Non-route
executions do not receive fabricated `context.route`, target, or matched-rule
values.

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
