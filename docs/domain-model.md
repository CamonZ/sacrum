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

**Execution tracking** — Every step transition creates an immutable `StepExecution` record capturing the step name, status, and optional LLM metadata (model, provider, token counts, cost, duration). Session logs attach free-text content to executions.

**Real-time updates** — State changes broadcast to a Phoenix channel (`ProjectChannel`) keyed by project ID (`project:<project_id>`), so connected clients receive live events for task, workflow, and step mutations.

## Domain Model

```
User
 └── Project
      ├── Workflow
      │    ├── WorkflowStep ──→ StepTransition (step-to-step edges)
      │    └── WorkflowTransition (workflow-to-workflow edges)
      └── Task
           ├── TaskSection ──→ CodeRef
           ├── CodeRef (direct)
           ├── TaskHierarchy (parent ← child)
           ├── TaskDependency (task ← depends_on)
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
| `createStepExecution` | `task_id!`, `workflow_id!`, `step_name!`, `status`, `context`, `prompt`, `output`, `transition_result`, `model`, `model_provider`, `input_tokens`, `output_tokens`, `cost`, `duration_ms` | `:step_execution` |
| `updateStepExecution` | `id!`, `step_name`, `status`, `context`, `prompt`, `output`, `transition_result`, `model`, `model_provider`, `input_tokens`, `output_tokens`, `cost`, `duration_ms` | `:step_execution` |
| `createSessionLog` | `step_execution_id!`, `content!` | `:session_log` |
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

### Event Types

| Event | Payload | Description |
|-------|---------|-------------|
| `task_created` / `task_updated` / `task_deleted` | Task fields | Task lifecycle changes |
| `workflow_created` / `workflow_updated` / `workflow_deleted` | Workflow fields | Workflow lifecycle |
| `step_created` / `step_updated` / `step_deleted` | Step fields | WorkflowStep lifecycle |
| `step_transition_created` / `step_transition_deleted` | Transition fields | Step-to-step edges |
| `step_execution_created` | Execution fields | New execution started |
| `step_execution_status_changed` | Execution fields | Status update (entered, completed, etc.) |
| `session_log_created` | Log fields | New log entry attached |
| `section_created` / `section_updated` / `section_deleted` | Section fields | Task section changes |
| `run_step` | Execution + step config | **Daemon only** — Run a step |
| `cancel_step` | Execution ID, task ID | **Daemon only** — Cancel running step |

> **Implementation:** See `SacrumWeb.ProjectChannel` and `Sacrum.Repo.Broadcaster`.

## Architecture Pattern

The codebase uses a **three-layer architecture** (Accounts → Repo → Ecto) instead of Phoenix contexts. See [Repository & Accounts Pattern](patterns.md) for the full reference, including GenericRepo, GenericResource, and Accounts layer documentation.

| Entity | Schema | Repository | Accounts | GraphQL Type |
|--------|--------|------------|----------|--------------|
| Task | `Schemas.Task` | `Repo.Tasks` | `Accounts.Tasks` | `task_type.ex` |
| Workflow | `Schemas.Workflow` | `Repo.Workflows` | `Accounts.Workflows` | `workflow_type.ex` |
| WorkflowStep | `Schemas.WorkflowStep` | `Repo.WorkflowSteps` | `Accounts.WorkflowSteps` | `workflow_step_type.ex` |
| Section | `Schemas.TaskSection` | `Repo.TaskSections` | `Accounts.Sections` | `section_types.ex` |
| StepExecution | `Schemas.StepExecution` | `Repo.StepExecutions` | `Accounts.StepExecutions` | `execution_types.ex` |
| Project | `Schemas.Project` | `Repo.Projects` | `Accounts.Projects` | `project_type.ex` |

Complex operations (transition syncing, workflow assignment, step movement) use `Ecto.Multi` for transactional safety. Dependency management includes BFS shortest-path and DFS cycle-detection algorithms.
