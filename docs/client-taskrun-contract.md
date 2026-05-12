# GUI/CLI TaskRun Contract

This document is the client-facing contract for the TaskRun lifecycle changes shipped through the TaskRun epic and the `human_input` workflow step work.

For the canonical backend model, see [Domain Model: Status and Run State](domain-model.md#status-and-run-state). This document translates that model into GUI and CLI implementation guidance.

The most important migration is:

> Do not use `Task.status` to represent active automation. Use `runControls`, `activeRun`, and `TaskRun.status`.

## Client Mental Model

Sacrum now separates four different questions:

| Question | Field to use | Client interpretation |
|----------|--------------|-----------------------|
| What is this task? | `Task` | The durable work item: title, hierarchy, workflow assignment, current step, sections, refs. |
| Where is the task in the workflow? | `Task.workflow`, `Task.currentStep` | The current workflow position. |
| Is automation currently running or waiting? | `TaskRun.status` | The durable run lifecycle. |
| What happened during an individual attempt? | `StepExecution.status` | Attempt history, prompt/output/logs/LLM metadata. |

`TaskRun` is not a replacement for `Task`. It is a run session for automation over a task. A task can have many historical TaskRuns, but should be represented with at most one active run in normal client state.

Chat runs that create tasks use a separate `ChatRun` / `ChatSession`
contract. Do not represent those conversations as `TaskRun`s. If a chat run
creates tasks, clients should use each task's chat-origin link to navigate back
to the run, with session detail available when a specific execution attempt
matters. See [Chat Runs Contract](chat-runs.md).

See [Domain Model: Status and Run State](domain-model.md#status-and-run-state) for the source-of-truth field ownership.

## Representing TaskRuns

Recommended client state shape:

```ts
type TaskRunStatus =
  | "queued"
  | "executing"
  | "waiting"
  | "stopping"
  | "stopped"
  | "completed"
  | "failed";

type TaskRunSummary = {
  id: string;
  taskId: string;
  projectId: string;
  status: TaskRunStatus;
  startedAt: string;
  endedAt: string | null;
  stopRequestedAt: string | null;
  latestStepExecutionId: string | null;
  outcomeKind: string | null;
  outcomeContext: Record<string, unknown> | null;
  parentTaskRunId: string | null;
  rootTaskRunId: string | null;
  triggeredByStepExecutionId: string | null;
};

type TaskRunControls = {
  runnable: boolean;
  stoppable: boolean;
  disabledReasonCode:
    | "active_run"
    | "archived"
    | "blocked"
    | "completed"
    | "missing_workflow"
    | "orchestrator_active"
    | "stale_active_run"
    | "stopping"
    | null;
  disabledReason: string | null;
  activeRun: TaskRunSummary | null;
};

type TaskRowState = {
  task: Task;
  workflowPosition: WorkflowStep | null;
  runControls: TaskRunControls;
  runHistory?: TaskRunSummary[];
};
```

The GUI can store this as `TaskRowState`; the CLI can compute the same shape transiently for list/detail commands.

### Status Display Rules

| `TaskRun.status` | Active? | Terminal? | Suggested label | Controls |
|------------------|---------|-----------|-----------------|----------|
| `queued` | yes | no | Queued | Stop if `runControls.stoppable` |
| `executing` | yes | no | Running | Stop if `runControls.stoppable` |
| `waiting` | yes | no | Waiting | Stop if `runControls.stoppable` |
| `stopping` | yes | no | Stopping | Disable Run and Stop |
| `stopped` | no | yes | Stopped | Historical |
| `completed` | no | yes | Completed | Historical |
| `failed` | no | yes | Failed | Historical |

Display `waiting` as active work, not as a completed or idle state. A waiting run may be blocked on child runs, a `human_input` step, or another orchestrated wait.

See [Domain Model: TaskRun.status](domain-model.md#taskrunstatus) for canonical lifecycle values and predicate semantics.

### Current Attempt

Use `TaskRun.latestStepExecutionId` and `TaskRun.latestStepExecution` for the current or most recent attempt in the run.

Do not derive run failure from `StepExecution.status == "failed"`. A failed step execution can be retried while the TaskRun remains active. Show the failed attempt in history, but keep the task row in an active/stoppable state if `activeRun.status` is still `queued`, `executing`, or `waiting`.

See [Domain Model: StepExecution.status](domain-model.md#stepexecutionstatus) for the attempt-level status boundary.

### Run History

Use `taskRuns(taskId)` for a task-local run history and `taskRunTrace(rootTaskRunId)` for recursive parent/child orchestration.

Do not infer TaskRun parentage from task hierarchy. Parent/child run lineage is explicit:

- `parentTaskRunId`
- `rootTaskRunId`
- `triggeredByStepExecutionId`

If those fields are null, treat the run as a standalone/root run, even if the task has a parent task.

See [Domain Model: Child Run Lineage](domain-model.md#child-run-lineage) for the backend lineage rule.

## Task Status Compatibility

`Task.status` remains in GraphQL and filters for compatibility, but new derivations only write:

- `ready`
- `done`

Older rows and filters may still contain `running` or `waiting`, but new GUI/CLI work should not depend on those values.

See [Domain Model: Task.status](domain-model.md#taskstatus) for the compatibility contract.

Replace old client behavior like:

```graphql
tasks(projectId: "...", status: "running") { id title status }
```

with either:

```graphql
tasks(projectId: "...") {
  id
  title
  runControls {
    activeRun { id status }
  }
}
```

or task-specific queries such as `activeRun(taskId: "...")`.

## GraphQL Contract

### Task List / Detail

Use this shape for task list rows and task detail headers:

```graphql
query TaskList($projectId: Uuid4!) {
  tasks(projectId: $projectId) {
    id
    shortId
    title
    status
    workflowId
    currentStepId
    currentStep {
      id
      name
      stepType
      outputSchema
      prompt
    }
    runControls {
      runnable
      stoppable
      disabledReasonCode
      disabledReason
      activeRun {
        id
        taskId
        projectId
        status
        startedAt
        endedAt
        stopRequestedAt
        latestStepExecutionId
        outcomeKind
        outcomeContext
        parentTaskRunId
        rootTaskRunId
        triggeredByStepExecutionId
        latestStepExecution {
          id
          taskRunId
          stepName
          status
          output
          handoff
          insertedAt
          updatedAt
        }
      }
    }
  }
}
```

Use `runControls.runnable` and `runControls.stoppable` directly for Run/Stop button state. Do not recalculate these rules in the client.

### Pipeline Summary

Pipeline clients should use `pipelineCounts` as the canonical per-step summary.
`activeCount` is a scalar convenience alias for `pipelineCounts.active`.
`runningCount` remains available during client migration, but it is a
compatibility alias for the same active `TaskRun.status` count; it is not based
on `StepExecution.status`.

```graphql
query PipelineSummary($projectId: Uuid4!) {
  pipelineSummary(projectId: $projectId) {
    id
    name
    workflowSteps {
      id
      name
      taskCounts {
        epic
        ticket
        task
      }
      activeCount
      runningCount
      pipelineCounts {
        epic
        ticket
        task
        active
      }
    }
  }
}
```

Task buckets count non-archived tasks at each step. The active bucket counts
active `TaskRun` rows for those tasks with statuses `queued`, `executing`,
`waiting`, or `stopping`.

### Run Workflow

```graphql
mutation RunWorkflow($taskId: Uuid4!) {
  runWorkflow(taskId: $taskId) {
    id
    taskId
    projectId
    status
    startedAt
    latestStepExecutionId
  }
}
```

After this mutation, refresh the task row or rely on `task_run_created` / `task_run_updated` WebSocket events.

### Stop Run

Prefer stopping by `taskRunId` when the client already has `runControls.activeRun.id`.

```graphql
mutation StopRun($taskRunId: Uuid4!) {
  stopRun(taskRunId: $taskRunId) {
    id
    taskId
    status
    stopRequestedAt
    endedAt
  }
}
```

`stopRun(taskId: ...)` is also valid. Provide exactly one of `taskId` or `taskRunId`; providing both is an error. Calling `stopRun(taskId: ...)` when no active run exists returns `null`.

### Task Run History

```graphql
query TaskRuns($taskId: Uuid4!) {
  taskRuns(taskId: $taskId) {
    id
    taskId
    status
    startedAt
    endedAt
    latestStepExecutionId
    outcomeKind
    outcomeContext
  }
}
```

### Recursive Run Trace

Use this for trace/debug views that need parent/child orchestration.

```graphql
query TaskRunTrace($rootTaskRunId: Uuid4!) {
  taskRunTrace(rootTaskRunId: $rootTaskRunId) {
    rootTaskRunId
    taskRuns {
      id
      taskId
      status
      parentTaskRunId
      rootTaskRunId
      triggeredByStepExecutionId
      latestStepExecutionId
      outcomeKind
      outcomeContext
      startedAt
      endedAt
    }
    stepExecutions {
      id
      taskId
      taskRunId
      workflowId
      stepName
      status
      output
      transitionResult
      handoff
      insertedAt
      updatedAt
      sessionLogs {
        id
        content
        insertedAt
      }
    }
    sessionLogs {
      id
      stepExecutionId
      content
      insertedAt
    }
  }
}
```

## WebSocket Contract

Connect with the API token, then join:

```text
project:<project_id>
```

Default clients receive UI-facing events. Daemon clients use `client_type: "daemon"` and only receive daemon commands.

Handle these events for run-aware GUI/CLI state:

| Event | Client action |
|-------|---------------|
| `task_created` / `task_updated` / `task_deleted` | Upsert/remove task row. The `task_updated` payload carries `archived` so archive/unarchive toggles can immediately move the row in or out of pipeline buckets without a refetch. |
| `step_execution_created` | Append attempt history; update latest execution view if it belongs to the active run. Do **not** use this as a from/to step signal for pipeline counts; not every step transition dispatches a new execution. |
| `step_execution_status_changed` | Update attempt history. Do not infer run terminal state from this alone. |
| `task_run_created` | Upsert TaskRun; set `task.runControls.activeRun` from payload if present. |
| `task_run_updated` | Upsert TaskRun; replace row controls with payload `run_controls`. |
| `task_run_step_changed` | Emitted whenever a task's `current_step_id` changes while a TaskRun exists, and at run-end paths (completion, retry exhaustion, stop). Lets pipeline views decrement the `from_step_id` bucket and increment the `to_step_id` bucket without refetching. |
| `task_step_changed` | Emitted whenever a task's `current_step_id` changes outside orchestrator execution (manual `assign_workflow`, `advance_to_step`, `move_to_step`). Same pipeline use as `task_run_step_changed`, without `task_run_id` / `status` since no run is involved. |
| `session_log_created` | Append log to the matching step execution. |

Channel payloads are snake_case. GraphQL fields are camelCase.

`task_run_created` and `task_run_updated` payloads include:

```ts
type TaskRunChannelBase = {
  id: string;
  task_id: string;
  project_id: string;
  status: TaskRunStatus;
  started_at: string;
  ended_at: string | null;
  stop_requested_at: string | null;
  latest_step_execution_id: string | null;
  outcome_kind: string | null;
  outcome_context: Record<string, unknown> | null;
  parent_task_run_id: string | null;
  root_task_run_id: string | null;
  triggered_by_step_execution_id: string | null;
  inserted_at: string;
  updated_at: string;
};

type TaskRunChannelPayload = TaskRunChannelBase & {
  run_controls: {
    runnable: boolean;
    stoppable: boolean;
    disabled_reason_code: string | null;
    disabled_reason: string | null;
    active_run: TaskRunChannelBase | null;
  } | null;
};
```

When applying a `task_run_updated` event, prefer the included `run_controls` over local recomputation.

`task_run_step_changed` is an additive pipeline-oriented signal. It does not
replace `task_updated` or `task_run_updated`; clients still need those for full
task and run state. The payload shape is:

```ts
type TaskRunStepChangedPayload = {
  task_run_id: string;
  task_id: string;
  from_step_id: string | null;
  to_step_id: string | null;
  status: TaskRunStatus;
  level: "epic" | "ticket" | "task";
};
```

- `from_step_id` is the task's `current_step_id` before the transition.
- `to_step_id` is the task's new `current_step_id`, or `null` when the event
  fires at a run-end path (completion, retry exhaustion, stop) because the run
  is leaving active statuses.
- `status` is the wire-form `TaskRun.status` after the transition.
- `level` mirrors `Task.level`, matching the per-level pipeline buckets.

`task_step_changed` is the parallel signal for manual moves (no TaskRun involved):

```ts
type TaskStepChangedPayload = {
  task_id: string;
  from_step_id: string | null;
  to_step_id: string | null;
  workflow_id: string;
  level: "epic" | "ticket" | "task";
};
```

- Fires from `assign_workflow` (initial assignment to a workflow's first step),
  `advance_to_step` (server-allowed step change), and `move_to_step` (step change
  requiring a transition edge).
- Only emitted when `from_step_id != to_step_id`. Idempotent re-assigns to the
  same step do not emit.
- `from_step_id` may be `null` for the first workflow assignment.
- Manual moves are blocked when an orchestrator is running for the task, so a
  client never receives both `task_run_step_changed` and `task_step_changed` for
  the same transition.

## Human Input

`human_input` is currently a workflow-step primitive, not a completed product surface.

Clients may display a waiting human gate when:

- `TaskRun.status == "waiting"`
- the latest/current `StepExecution.status == "waiting"`
- the current or latest step has `stepType == "human_input"`

Recommended v1 behavior:

- Show the task, current step, rendered prompt, output schema, execution ID, and run ID.
- Do not render an Approve/Reject/Submit action yet.
- Allow Stop if `runControls.stoppable == true`.
- Link the future work to the platform discovery ticket `ca564fec` and GUI research ticket `8f2b4c7c`.

There is an internal backend resume path, but no GraphQL mutation for client submission yet. Do not attempt to complete a waiting `human_input` execution with `updateStepExecution`; that bypass path is intentionally blocked.

## CLI Guidance

Update CLI commands as follows:

- `list`: show a run state column from `runControls.activeRun.status`, not `Task.status`.
- `status` / `show`: show both workflow position and active run state.
- `run`: call `runWorkflow(taskId)`.
- `stop`: call `stopRun(taskRunId)` when an active run is known; otherwise call `stopRun(taskId)`.
- `trace`: use `taskRunTrace(rootTaskRunId)`.
- `logs`: prefer `StepExecution` and `SessionLog` data scoped by `TaskRun` when available.

Suggested CLI language:

```text
Task: abc123 Implement parser
Workflow: Coding / Review
Task status: ready (compat)
Run: executing taskRun=... latestStep=...
Controls: stoppable
```

For historical rows:

```text
Run history:
- completed  started=... ended=... outcome=completed
- failed     started=... ended=... outcome=retry_exhausted
- stopped    started=... ended=... outcome=null
```

## GUI Guidance

Represent TaskRun state as a first-class part of each task row:

- Primary task chip: title, level, priority, blockers.
- Workflow chip: current workflow/current step.
- Run chip: absent, queued, running, waiting, stopping, completed, failed, stopped.
- Controls: Run/Stop derived only from `runControls`.

Avoid showing `Task.status` as the main state chip. If it is still useful for debugging, label it as compatibility state.

For trace views, render TaskRuns as a tree keyed by `rootTaskRunId` and `parentTaskRunId`, with StepExecutions nested under the run that owns them.

## Acceptance Scenarios

Clients should pass these behavioral checks:

- A task with no active run and `runControls.runnable == true` shows Run enabled.
- A task with active `queued`, `executing`, or `waiting` run shows Stop enabled when `runControls.stoppable == true`.
- A `stopping` run disables Run and Stop.
- Terminal `stopped`, `completed`, and `failed` runs appear only in history unless they are the selected trace.
- A latest failed StepExecution does not make the task failed if the TaskRun is still active.
- A waiting `human_input` run renders as a blocking gate with no submit action yet.
- WebSocket `task_run_updated` updates the row without requiring a full task refetch.
