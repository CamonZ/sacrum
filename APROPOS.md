# Sacrum

Sacrum is an API-only workflow engine and task management system built with Phoenix 1.8 (Elixir) and PostgreSQL. It provides the backend for defining multi-step workflows, managing tasks through those workflows, and tracking execution history — all over a JSON REST API with bearer token authentication and real-time WebSocket updates.

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

All endpoints live under `/api` and require bearer token auth (`Authorization: Bearer sac_...`).

| Resource | Endpoint | Operations |
|---|---|---|
| Projects | `/api/projects` | CRUD |
| Workflows | `/api/workflows` | CRUD, transition sync via PATCH |
| Workflow Steps | `/api/workflow-steps` | CRUD, transition sync via PATCH |
| Tasks | `/api/tasks` | CRUD, filtered listing, ready query, tree view |
| Task Refs | `/api/tasks/:id/refs` | Create, list, delete code references |
| Task Workflow | `/api/tasks/:id/assign-workflow` | Assign/unassign workflow |
| Task Movement | `/api/tasks/:id/move-to` | Move task to next step |
| Task Blockers | `/api/tasks/:id/blockers` | Transitive blocker chain |
| Task Path | `/api/tasks/:id/path?to=` | Shortest dependency path |
| Task Tree | `/api/tasks/:id/tree` | Hierarchical subtree |
| Executions | `/api/executions/:id` | Show execution detail |
| Execution Logs | `/api/executions/:id/logs` | List session logs |

Task listing supports filters: `project_id`, `level`, `parent_id`, `search`, `blocked`, `status`, `tags`, `root_only`, `workflow_id`.

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

## Architecture Pattern

The codebase uses a **repository pattern** instead of Phoenix contexts:

- **Schemas** (`Sacrum.Repo.Schemas.*`) — Ecto schemas with changeset validation
- **Repositories** (`Sacrum.Repo.*`) — CRUD and domain queries per entity
- **Controllers** (`SacrumWeb.*Controller`) — Thin HTTP layer delegating to repos
- **JSON views** (`SacrumWeb.*JSON`) — Response serialization
- **Auth** (`Sacrum.Auth`) — Token generation, verification, expiration

Complex operations (transition syncing, workflow assignment, step movement) use `Ecto.Multi` for transactional safety. Dependency management includes BFS shortest-path and DFS cycle-detection algorithms.
