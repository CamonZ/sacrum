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

**Real-time updates** — State changes broadcast to a Phoenix channel (`ProjectChannel`) keyed by project slug, so connected clients receive live events for task, workflow, and step mutations.

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

### Core Queries

| Query | Arguments | Description |
|-------|-----------|-------------|
| `tasks` | `project_id` (required), `level`, `parent_id`, `status`, `tags`, `search`, `workflow_id`, `root_only`, `blocked` | List tasks with filters |
| `task` | `id` (required) | Single task by ID |
| `listReady` | `project_id` (required) | Tasks ready for work (no blockers, not completed) |
| `findPath` | `from_id`, `to_id` | Shortest dependency path between tasks |
| `workflows` | `project_id` (required) | List workflows |
| `workflowSteps` | `workflow_id` (required) | List steps in a workflow |

### Core Mutations

| Mutation | Arguments | Description |
|----------|-----------|-------------|
| `createTask` | `project_id`, `title`, `description`, `level`, `priority`, `tags`, `parent_id`, `sections` | Create a task |
| `updateTask` | `id`, `title`, `description`, `level`, `priority`, `tags`, `needs_human_review`, `parent_id`, `depends_on_ids`, `sections` | Update a task |
| `deleteTask` | `id`, `cascade` | Delete task (cascade removes children) |
| `assignWorkflow` | `task_id`, `workflow_id` | Assign task to a workflow |
| `unassignWorkflow` | `task_id` | Remove workflow from task |
| `moveToStep` | `task_id`, `step_id` | Move task to a specific step |
| `startStep` | `task_id` | Mark current step as in progress |
| `completeStep` | `task_id` | Mark current step as complete |
| `rejectStep` | `task_id`, `target_step_id`, `feedback` | Reject and send back to target step |
| `createTaskDependency` | `task_id`, `depends_on_id` | Add a dependency |
| `deleteTaskDependency` | `task_id`, `depends_on_id` | Remove a dependency |

> **Implementation:** See `lib/sacrum_web/graphql/schema.ex` for the full schema and `lib/sacrum_web/graphql/types/*.ex` for type definitions.

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

The codebase uses a **repository pattern** instead of Phoenix contexts:

| Layer | Location | Purpose |
|-------|----------|---------|
| Schemas | `lib/sacrum/repo/schemas/` | Ecto schemas with changeset validation |
| Repositories | `lib/sacrum/repo/` | CRUD and domain queries per entity |
| GraphQL Types | `lib/sacrum_web/graphql/types/` | Schema definitions, queries, mutations |
| Channel | `lib/sacrum_web/channels/project_channel.ex` | Real-time WebSocket broadcasts |
| Auth | `lib/sacrum/auth.ex` | Token generation, verification, expiration |

### Key Modules by Entity

| Entity | Schema | Repository | GraphQL Type |
|--------|--------|------------|--------------|
| Task | `Sacrum.Repo.Schemas.Task` | `Sacrum.Repo.Tasks` | `lib/sacrum_web/graphql/types/task_type.ex` |
| Workflow | `Sacrum.Repo.Schemas.Workflow` | `Sacrum.Repo.Workflows` | `lib/sacrum_web/graphql/types/workflow_type.ex` |
| WorkflowStep | `Sacrum.Repo.Schemas.WorkflowStep` | `Sacrum.Repo.WorkflowSteps` | `lib/sacrum_web/graphql/types/workflow_step_type.ex` |
| Section | `Sacrum.Repo.Schemas.TaskSection` | `Sacrum.Repo.TaskSections` | `lib/sacrum_web/graphql/types/section_types.ex` |
| StepExecution | `Sacrum.Repo.Schemas.StepExecution` | `Sacrum.Repo.StepExecutions` | `lib/sacrum_web/graphql/types/execution_types.ex` |
| Project | `Sacrum.Repo.Schemas.Project` | `Sacrum.Repo.Projects` | `lib/sacrum_web/graphql/types/project_type.ex` |

Complex operations (transition syncing, workflow assignment, step movement) use `Ecto.Multi` for transactional safety. Dependency management includes BFS shortest-path and DFS cycle-detection algorithms.
