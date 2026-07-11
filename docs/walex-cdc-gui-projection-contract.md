# WalEx CDC GUI Projection Contract

This document defines the default-client realtime contract that a WalEx CDC
projector must preserve for `SacrumWeb.ProjectChannel`.

The canonical machine-readable contract is
`Sacrum.Realtime.ProjectChannelCdcContract`. `ProjectChannel.intercept/1` is
driven by that module so the event surface and contract stay in sync.

## Scope

Default GUI/CLI clients receive committed state projections. Daemon clients are
outside this contract:

| Event | Reason |
| --- | --- |
| `run_step` | Daemon command dispatched to workers, not a GUI state projection. |
| `cancel_step` | Daemon command dispatched to workers, not a GUI state projection. |

The CDC projector must not emit daemon commands.

## Healthy Live CDC Path

For a healthy connected client, WalEx changes are applied in commit order after
the client's snapshot cursor. Each event is a projection of committed Postgres
rows and is complete enough for normal GUI store updates. Clients should not use
ordinary events as invalidation signals or perform routine GraphQL refetches
after each event.

Repo, Accounts, and routing paths must not emit these default-client events
directly. They commit rows; `Sacrum.Realtime.Cdc.Projector`
owns the ProjectChannel payload construction for regular clients. The only
imperative ProjectChannel broadcasts are daemon commands such as `run_step` and
`cancel_step`.

Channel payloads use `snake_case` keys. GraphQL uses `camelCase`.

Every default-client ProjectChannel payload carries `schema_version: 1`.
Clients should treat an unknown schema version as a binding/contract mismatch
instead of silently applying a payload with an unsupported shape.

## Event Mapping

| Event | Class | Source change image | Payload contract |
| --- | --- | --- | --- |
| `task_created` | Entity projection | `tasks` insert after image plus post-commit server-side run-control enrichment inputs. | Full task row plus `run_controls` with server-derived `runnable`, `stoppable`, reason fields, and `active_run`; clients can seed task controls before any `TaskRun` event exists. |
| `task_updated` | Entity projection | `tasks` update after image, with before `id`, plus post-commit server-side run-control enrichment inputs. | Same full task row plus replacement `run_controls`; clients upsert task state and controls without refetching, including when an active run changed in the same committed transaction. |
| `task_deleted` | Entity projection | `tasks` delete before image. | Tombstone with `id`, `current_step_id`, `workflow_id`, `level`, and `archived` from the before image so clients can remove the row and update pipeline buckets without a task-position cache. |
| `task_parent_changed` | Semantic delta | `tasks` update with before/after `parent_id`. | `{task_id, project_id, from_parent_id, to_parent_id, level}`. Gives tree stores the exact parent move while `task_updated` carries the full task row. |
| `task_dependency_created` | Relation change | `task_dependencies` insert after image. | Full dependency edge row: `id`, `task_id`, `depends_on_id`, `project_id`, timestamps. |
| `task_dependency_deleted` | Relation change | `task_dependencies` delete before image. | Full dependency edge tombstone with `id`, `task_id`, `depends_on_id`, `project_id`, timestamps. |
| `workflow_created` | Entity projection | `workflows` insert after image. | Full workflow row including default/final flags, ordering, metadata, `initial_step_id`, `kanban_column`, and `project_id`. |
| `workflow_updated` | Entity projection | `workflows` update after image. | Same full workflow row for graph/list replacement. |
| `workflow_deleted` | Entity projection | `workflows` delete before image. | `{id}` tombstone scoped by the project channel. |
| `step_created` | Entity projection | `workflow_steps` insert after image. | Full step row including prompt, output schema, step type, agent config, daemon logging flag, `workflow_id`, and `project_id`. |
| `step_updated` | Entity projection | `workflow_steps` update after image. | Same full step row for workflow editor and pipeline graph replacement. |
| `step_deleted` | Entity projection | `workflow_steps` delete before image. | `{id, workflow_id}` tombstone. |
| `step_transition_created` | Relation change | `step_transitions` insert after image. | Full edge row: `id`, `from_step_id`, `to_step_id`, `label`, `project_id`, timestamps. |
| `step_transition_deleted` | Relation change | `step_transitions` delete before image. | Full edge tombstone with `id`, `from_step_id`, `to_step_id`, `label`, `project_id`, and timestamps so clients can remove by id or endpoints without a transition cache. |
| `workflow_transition_created` | Relation change | `workflow_transitions` insert after image. | Full edge row: `id`, endpoints, optional `target_step_id`, `label`, `project_id`, timestamps. |
| `workflow_transition_deleted` | Relation change | `workflow_transitions` delete before image. | Full edge row, allowing clients to remove by id or endpoints. |
| `step_execution_created` | Entity projection | `step_executions` insert after image. | Full execution row including task/run/workflow/step/project ids, status, prompt/output, transition result, model metadata, legacy and expanded token counters, cost, duration, handoff, timestamps. |
| `step_execution_status_changed` | Status projection | `step_executions` update after image with before `status`. | Same full execution row. This updates attempt history only; clients must not infer terminal run state from it. |
| `task_run_created` | Entity projection | `task_runs` insert after image plus server-side run-control enrichment inputs. | Full TaskRun row plus `run_controls` with server-derived `runnable`, `stoppable`, reason fields, and `active_run`. |
| `task_run_updated` | Status projection | `task_runs` update after image with before `status` and `latest_step_execution_id`, plus server-side run-control enrichment inputs. | Same full TaskRun row plus replacement `run_controls`; clients should prefer these controls over local recomputation. |
| `task_run_step_changed` | Semantic delta | Derived from `tasks` and `task_runs`; see below. | `{task_run_id, task_id, from_step_id, to_step_id, status, level}`. |
| `task_step_changed` | Semantic delta | Derived from `tasks`; see below. | `{task_id, from_step_id, to_step_id, workflow_id, level}`. |
| `session_log_created` | Entity projection | `session_logs` insert after image. | Full log row: `id`, `step_execution_id`, `project_id`, `content`, `format`, nullable `logical_key`, timestamps. Clients append. |
| `session_log_updated` | Entity projection | `session_logs` update after image. | Full log row: `id`, `step_execution_id`, `project_id`, `content`, `format`, nullable `logical_key`, timestamps. Clients replace by `id`. |
| `section_created` | Entity projection | `task_sections` insert after image. | Full section row: `id`, `task_id`, `project_id`, type/content/order/done fields, timestamps. |
| `section_updated` | Entity projection | `task_sections` update after image. | Same full section row. |
| `section_deleted` | Entity projection | `task_sections` delete before image. | `{id, task_id}` tombstone. |
| `code_ref_created` | Relation change | `code_refs` insert after image. | Full code reference row: `id`, `task_id`, `section_id`, `project_id`, file path, line range, name, description, timestamps. |
| `code_ref_updated` | Relation change | `code_refs` update after image. | Same full code reference row for detail/evidence replacement. |
| `code_ref_deleted` | Relation change | `code_refs` delete before image. | Full code reference tombstone so clients can remove by id without refetching. |

## Derived Step Movement Events

`task_run_step_changed` is not a simple row mirror. It is a semantic pipeline
delta derived from persisted task and run rows:

- `task_run_id` comes from `task_runs.id`.
- `task_id` comes from `tasks.id`.
- `from_step_id` is `tasks.current_step_id` from the before image for movement
  events. For run-end events, it is the task's current step from the after image.
- `to_step_id` is `tasks.current_step_id` from the after image for movement
  events. It is `nil` when `task_runs.status` leaves active statuses at run end
  such as completion, retry exhaustion, or stop.
- `status` is the after-image `task_runs.status` encoded by
  `Sacrum.TaskRuns.Status.wire_value/1`.
- `level` is the after-image `tasks.level`.
- At root or child run start, emit once immediately after `task_run_created`, with
  `from_step_id: nil`, `to_step_id: tasks.current_step_id`, and the created
  TaskRun status. This must happen before the first `task_run_updated` dispatch
  event so a GUI can place the run in the pipeline before consuming run-state
  updates.

`task_step_changed` is the manual-move equivalent:

- It is derived from a `tasks` update where `current_step_id` changes outside
  orchestrator execution.
- `from_step_id` is before-image `tasks.current_step_id`.
- `to_step_id` is after-image `tasks.current_step_id`.
- `workflow_id` and `level` come from the after image.
- Emit only when `from_step_id != to_step_id`.
- Manual moves are blocked while an orchestrator owns the task, so this event
  must not be emitted for the same transition as `task_run_step_changed`.

## Hierarchy And Relation Events

`task_parent_changed` is emitted for `tasks.parent_id` updates where the parent
actually changes. It is paired with the ordinary `task_updated` projection:
clients should replace the task row from `task_updated` and use
`task_parent_changed` to move the task between tree buckets without comparing
against stale local hierarchy state.

`task_dependency_created` and `task_dependency_deleted` are complete edge
projections from `task_dependencies`. Dependency/blocker views should apply
these edge events directly. They are not invalidation hints and should not cause
routine task-list refetches.

`code_ref_created`, `code_ref_updated`, and `code_ref_deleted` are complete
`code_refs` projections. Task detail, section detail, and evidence views should
upsert or remove the reference by id using these events.

## Run Control Enrichment

`run_controls` is part of task and TaskRun client payloads, but it is not derived
from a single row alone. The WalEx projector enqueues the committed row event
into Sacrum; a Sacrum process then enriches the event with the same server-side
presenter used by the current channel path: `Sacrum.TaskRuns.RunControls`.

That presenter combines:

- the task after image and, for TaskRun events, the TaskRun after image;
- the owning task row, including workflow/current-step/archive/completion state;
- direct blocker rows and blocker task completion state;
- the latest step execution status when checking stale active runs;
- `TaskRegistry` process state for active orchestrators.

The payload remains a complete replacement for GUI controls. For
`task_created` and `task_updated`, the task after image is paired with the
current active run as observed after commit; if the task and run changes were
committed together, the task event reflects those post-commit run conditions.
The later `task_run_created` or `task_run_updated` event is a compatible
replacement update. The boundary is that WalEx supplies committed row changes,
while Sacrum performs synchronous server enrichment before pushing to
subscribers. Do not design this path as a pure CDC publisher that bypasses
Sacrum runtime state.

## Initial Snapshot

Initial load is separate from healthy live CDC. A GUI store should:

1. Capture a CDC cursor/LSN for the snapshot boundary.
2. Read all project rows at or before that boundary.
3. Build the equivalent of the GraphQL task list/detail, pipeline summary, run
   trace, and sections.
4. Include archived tasks when building a full local store.
5. Apply WalEx changes committed after the snapshot cursor in order.

Snapshot source tables are:

- `projects`
- `workflows`
- `workflow_steps`
- `step_transitions`
- `workflow_transitions`
- `tasks`
- `task_runs`
- `step_executions`
- `session_logs`
- `task_sections`
- `task_dependencies`
- `code_refs`

## Reconnect And Gap Recovery

For a short reconnect where the last acknowledged CDC cursor is still retained,
replay changes after that cursor in commit order. Clients may de-duplicate by
event name plus primary key/update timestamp if transport retries produce a
duplicate delivery.

If the cursor is missing, retention has expired, or sequence continuity is
uncertain, treat it as a gap:

1. Stop applying speculative incremental counts.
2. Re-run the initial snapshot contract.
3. Resume live CDC from the new snapshot cursor.

Refetch is a recovery path, not the routine live-event path.
