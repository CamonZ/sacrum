# Repository & Accounts Pattern

Sacrum uses a three-layer architecture instead of Phoenix contexts. Data flows through three layers: **Accounts** (business logic) → **Repo** (database operations) → **Ecto/PostgreSQL**.

```
GraphQL Resolver
    │
    ▼
Accounts Layer (Sacrum.Accounts.*)       ← User-scoped access, business logic, broadcasting
    │  uses GenericResource macro
    ▼
Repository Layer (Sacrum.Repo.*)         ← Database CRUD, queries, transactions
    │  uses GenericRepo macro
    ▼
Ecto / PostgreSQL
```

### Data Flow Example

```
GraphQL Resolver → Accounts.Tasks.insert(user_id, project_id, attrs)
                     → Repo.Tasks.insert(changeset)  [GenericRepo]
                       → Ecto / PostgreSQL
                     ← {:ok, task}
                     → Broadcaster.broadcast(:task_created, :project)
                       → ProjectChannel
```

## Directory Structure

```
lib/sacrum/
├── generic_repo.ex                   # Macro: base CRUD for any schema
├── generic_resource.ex               # Macro: user-scoped access layer
├── repo.ex                           # Ecto.Repo module
├── accounts/                         # Business logic layer
│   ├── projects.ex                   # Project operations
│   ├── tasks.ex                      # Task operations + dependency management
│   ├── workflows.ex                  # Workflow operations + transition syncing
│   ├── workflow_steps.ex             # Step operations
│   ├── sections.ex                   # Section operations
│   ├── code_refs.ex                  # Code reference operations
│   ├── workflow_transitions.ex       # Workflow transition operations
│   ├── step_transitions.ex           # Step transition operations
│   ├── step_executions.ex            # Execution operations
│   └── session_logs.ex               # Session log operations
└── repo/
    ├── schemas/                      # Ecto schemas with changesets
    │   ├── task.ex
    │   ├── task_section.ex
    │   ├── task_dependency.ex
    │   ├── workflow.ex
    │   ├── workflow_step.ex
    │   ├── step_transition.ex
    │   ├── step_execution.ex
    │   ├── workflow_transition.ex
    │   ├── session_log.ex
    │   ├── code_ref.ex
    │   ├── user.ex
    │   ├── project.ex
    │   └── api_token.ex
    ├── tasks.ex                      # Task CRUD + filtering + validation
    ├── task_sections.ex              # Section management
    ├── task_dependencies.ex          # Dependency DAG with cycle detection
    ├── task_hierarchy.ex             # Parent-child tree relationships
    ├── task_workflows.ex             # Workflow assignment, step transitions
    ├── workflows.ex                  # Workflow CRUD + transition sync
    ├── workflow_steps.ex             # Step management
    ├── workflow_transitions.ex       # Workflow-to-workflow edges
    ├── step_transitions.ex           # Step-to-step edges
    ├── step_executions.ex            # Execution audit trail
    ├── session_logs.ex               # Execution log entries
    ├── code_refs.ex                  # File/line references
    ├── users.ex                      # User CRUD
    ├── projects.ex                   # Project CRUD
    ├── api_tokens.ex                 # Token management
    ├── broadcaster.ex                # Centralized channel broadcasts
    └── sync_helper.ex                # Generic diff-and-sync for transitions
```

## Layer 1: GenericRepo (Database Operations)

`Sacrum.GenericRepo` (`lib/sacrum/generic_repo.ex`) is a macro that generates 12 overridable CRUD functions for any Ecto schema. Repo modules use it as their base and override functions for domain-specific behavior.

**Options:** `schema` (required) — the Ecto schema module.

```elixir
defmodule Sacrum.Repo.Tasks do
  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Task
  # Generates: get/1-2, get!/1, get_by/1, all/0-1,
  #            query/0, count/0-1, exists?/1,
  #            insert/1, update/1, delete/1
end
```

### Generated Functions

| Function | Return Type | Description |
|----------|-------------|-------------|
| `get(id)` | `{:ok, record} \| {:error, :not_found}` | Fetch by primary key |
| `get(id, preloads: [...])` | `{:ok, record} \| {:error, :not_found}` | Fetch with preloads |
| `get!(id)` | `record \| raises` | Fetch or raise |
| `get_by(conditions: [...])` | `{:ok, record} \| {:error, :not_found}` | Fetch by conditions |
| `get_by(conditions: [...], preloads: [...])` | `{:ok, record} \| {:error, :not_found}` | With preloads |
| `all()` | `[record]` | All records |
| `all(conditions: [...], order_by: [...])` | `[record]` | Filtered and ordered |
| `query()` | `Ecto.Query.t()` | Base query for custom composition |
| `count()` | `integer` | Total count |
| `exists?(id)` | `boolean` | Check existence |
| `insert(changeset)` | `{:ok, record} \| {:error, changeset}` | Insert |
| `update(changeset)` | `{:ok, record} \| {:error, changeset}` | Update |
| `delete(record)` | `{:ok, record} \| {:error, changeset}` | Delete |

### Structured Opts

All query functions accept structured opts with `:conditions`, `:preloads`, and `:order_by` keys. Also accepts flat keyword clauses for backward compatibility.

```elixir
# Structured opts
Tasks.get_by(conditions: [short_id: "x123"], preloads: [:sections])
Tasks.all(conditions: [project_id: pid], order_by: [asc: :inserted_at])

# Flat clauses (backward compat)
Tasks.get_by(short_id: "x123")
```

### Repo Specialization

Repo modules override GenericRepo functions for domain-specific behavior:

- **`apply_filters`** — Dynamic query composition (e.g., `Tasks.list_tasks/1`)
- **Complex queries** — Recursive CTEs, subqueries, raw SQL (e.g., `TaskDependencies.find_path/2`)
- **Multi-arity insert** — Accept structs or raw IDs (e.g., `Tasks.insert(%Project{}, attrs)`)
- **Transaction management** — `Ecto.Multi` for atomic operations (e.g., `TaskWorkflows.assign_workflow/2`)

## Layer 2: GenericResource (User-Scoped Access)

`Sacrum.GenericResource` (`lib/sacrum/generic_resource.ex`) is a macro that wraps a GenericRepo module, automatically injecting `user_id` into all conditions. It provides user-scoped read operations.

**Options:**
- `repo` (required) — the repo module to delegate to
- `preloads` (optional) — associations to preload on every query
- `default_order` (optional, default: `[asc: :inserted_at]`) — default ordering

```elixir
defmodule Sacrum.Accounts.Tasks do
  use Sacrum.GenericResource,
    repo: Sacrum.Repo.Tasks,
    preloads: [:sections],
    default_order: [asc: :inserted_at]
end
```

### Generated Functions

| Function | Return Type | Description |
|----------|-------------|-------------|
| `get_by(user_id, opts)` | `{:ok, record} \| {:error, :not_found}` | Fetch one, scoped to user |
| `list_by(user_id)` | `[record]` | All records for user |
| `list_by(user_id, opts)` | `[record]` | Filtered records for user |

### Preload Merging

Module-level preloads are merged with runtime preloads. For example, if `preloads: [:sections]` is configured and a caller passes `preloads: [:parent]`, both `:sections` and `:parent` will be preloaded.

```elixir
# Module-level preloads [:sections] + runtime preloads [:parent]
Accounts.Tasks.get_by(user_id, conditions: [id: id], preloads: [:parent])
# → preloads [:sections, :parent]
```

## Layer 3: Accounts (Business Logic)

Accounts modules (`lib/sacrum/accounts/`) sit on top of GenericResource. They:

1. **Use GenericResource** for all read operations (`get_by`, `list_by`)
2. **Add custom write operations** (insert/update/delete) with changeset construction
3. **Handle broadcasting** via `Broadcaster` after successful operations
4. **Translate domain errors** from atoms to user-facing messages (see [Error Handling](error-handling.md))

### Simple Accounts Module

```elixir
# lib/sacrum/accounts/projects.ex
defmodule Sacrum.Accounts.Projects do
  use Sacrum.GenericResource,
    repo: Sacrum.Repo.Projects,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.Projects, as: ProjectsRepo
  alias Sacrum.Repo.Schemas.Project

  def insert(user_id, attrs) when is_binary(user_id) do
    %Project{user_id: user_id}
    |> Project.create_changeset(attrs)
    |> ProjectsRepo.insert()
  end

  def update(%Project{} = project, attrs) do
    project
    |> Project.update_changeset(attrs)
    |> ProjectsRepo.update()
  end

  def delete(%Project{} = project), do: ProjectsRepo.delete(project)
end
```

### Complex Accounts Module

Complex modules add domain-specific operations, validation pipelines, and error translation:

```elixir
# lib/sacrum/accounts/tasks.ex — insert with auto-workflow and broadcasting
def insert(user_id, project_id, attrs) do
  %Task{project_id: project_id, user_id: user_id}
  |> Task.create_changeset(attrs)
  |> TasksRepo.insert()
  |> preload_sections()
  |> maybe_assign_default_workflow(project_id)
  |> Broadcaster.broadcast(:task_created, :project)
end

# update with validation pipeline
def update(%Task{} = task, attrs) do
  task = Repo.preload(task, :sections)

  with :ok <- validate_section_ownership(task, attrs),
       {:ok, updated_task} <- do_update_task(task, attrs),
       {:ok, updated_task} <- maybe_update_parent(updated_task, attrs),
       :ok <- maybe_update_dependencies(updated_task, attrs) do
    Broadcaster.broadcast({:ok, updated_task}, :task_updated, :project)
  end
end
```

### Key Distinction

- **Repo modules** = database operations only. No user scoping, no broadcasting, no business rules.
- **Accounts modules** = business logic + user scoping + broadcasting. GraphQL resolvers call these, never Repo modules directly (except for cross-domain operations like `TaskWorkflows` and `TaskDependencies`).

> **Known violation:** `Repo.Tasks` currently contains broadcasting, validation pipelines, and error translation that belong in `Accounts.Tasks`. New code should follow the intended separation — keep Repo modules focused on database operations and put business logic in the Accounts layer.

## Schema Conventions

### Primary Keys & Timestamps

All schemas use UUID primary keys and microsecond timestamps:

```elixir
@primary_key {:id, :binary_id, autogenerate: true}
@foreign_key_type :binary_id

timestamps(type: :utc_datetime_usec)
```

### Separate Changesets per Operation

Schemas define distinct changesets for create vs update, with different allowed fields:

```elixir
defmodule Sacrum.Repo.Schemas.Task do
  @create_fields [:title, :description, :level, :priority, :tags]
  @update_fields [:title, :description, :level, :priority, :tags,
                  :needs_human_review, :review_comment, :started_at,
                  :completed_at, :revision_feedback]

  def create_changeset(task, attrs) do
    task
    |> cast(attrs, @create_fields)
    |> validate_required([:title])
    |> cast_assoc(:sections, with: &section_changeset/2)
    |> maybe_generate_short_id()
    |> unique_constraint(:short_id)
    |> foreign_key_constraint(:project_id)
  end

  def update_changeset(task, attrs) do
    task
    |> cast(attrs, @update_fields)
    |> validate_required([:title])
    |> cast_assoc(:sections, with: &section_changeset/2)
  end
end
```

### Programmatic Fields

Fields set by the system (e.g., `user_id`, `project_id`) are **never** in `cast` — they're set explicitly on the struct before the changeset:

```elixir
def insert(project_id, user_id, attrs) do
  %Task{project_id: project_id, user_id: user_id}
  |> Task.create_changeset(attrs)
  |> Repo.insert()
end
```

### Associations

```elixir
# Standard belongs_to
belongs_to :project, Sacrum.Repo.Schemas.Project

# has_many with cascade delete on replace
has_many :sections, Sacrum.Repo.Schemas.TaskSection, on_replace: :delete

# Self-referential hierarchy
belongs_to :parent, Sacrum.Repo.Schemas.Task
has_many :children, Sacrum.Repo.Schemas.Task, foreign_key: :parent_id

# Through association for many-to-many via join table
has_many :task_dependencies, TaskDependency, foreign_key: :task_id
has_many :blockers, through: [:task_dependencies, :depends_on]
```

## Repo Module Patterns

Repo modules override GenericRepo functions for domain-specific query logic (filtering, CTEs, subqueries). Business logic and broadcasting should live in the Accounts layer.

> **Note:** The examples below are from `Repo.Tasks`, which currently violates this by including broadcasting and validation. They illustrate working patterns but new code should place business logic in the corresponding Accounts module.

### Multi-Arity Insert

Repo modules accept different input shapes — structs or raw IDs:

```elixir
# Accept a Project struct (extracts IDs)
def insert(%Project{id: project_id, user_id: user_id}, attrs) when is_binary(user_id) do
  insert(project_id, user_id, attrs)
end

# Accept raw IDs
def insert(project_id, user_id, attrs) when is_binary(project_id) and is_binary(user_id) do
  %Task{project_id: project_id, user_id: user_id}
  |> Task.create_changeset(attrs)
  |> Repo.insert()
  |> preload_sections()
  |> Broadcaster.broadcast(:task_created, :project)
end
```

### Delete with Options

```elixir
def delete(%Task{} = task, opts \\ []) do
  cascade = Keyword.get(opts, :cascade, true)

  unless cascade do
    from(t in Task, where: t.parent_id == ^task.id)
    |> Repo.update_all(set: [parent_id: nil])
  end

  case Repo.delete(task) do
    {:ok, deleted_task} ->
      Broadcaster.broadcast_event(deleted_task, :task_deleted, :project)
      {:ok, deleted_task}
    error -> error
  end
end
```

### Filtering with Dynamic Queries

List functions compose filters dynamically:

```elixir
def list_tasks(opts) do
  Task
  |> apply_filters(opts)
  |> apply_task_preloads(opts)
  |> order_by([t], asc: t.inserted_at)
  |> Repo.all()
end

defp apply_filter(query, :blocked, false) do
  from(t in query,
    where: t.id not in subquery(
      from(d in TaskDependency,
        join: dep in Task, on: dep.id == d.depends_on_id,
        where: is_nil(dep.completed_at),
        select: d.task_id,
        distinct: true
      )
    )
  )
end

defp apply_filter(query, :status, status) do
  from(t in query, where: t.status == ^status)
end
```

## Ecto.Multi for Transactions

Multi-step operations that must be atomic use `Ecto.Multi`:

```elixir
def assign_workflow(%Task{} = task, %Workflow{} = workflow) do
  workflow = Repo.preload(workflow, :workflow_steps)

  case do_assign_workflow(task, workflow) do
    {:ok, %{task: task}} ->
      broadcast_task_changed(task)
      {:ok, task}

    {:error, _op, changeset, _changes} ->
      {:error, changeset}
  end
end

defp do_assign_workflow(task, workflow) do
  case resolve_initial_step(workflow) do
    {:ok, initial_step} ->
      Multi.new()
      |> Multi.update(:task, task_workflow_changeset(task, workflow.id, initial_step.id))
      |> Multi.insert(:step_execution, step_execution_attrs(task, workflow, initial_step))
      |> Repo.transaction()

    {:error, _} = error ->
      error
  end
end
```

Key rules:
- Validate business rules **before** building the Multi (not inside it)
- Broadcast **after** the transaction succeeds
- Normalize Multi errors to `{:error, changeset}` in the `case` clause
- Use `case` for single-clause matching — single-step `with` is an antipattern (see [Error Handling](error-handling.md))
- Avoid pipe-chaining into `case` — extract the pipeline into a private `do_*` function and match on its result in the public function

## Preloading

Preloading is always caller-managed. No repo module auto-preloads associations.

```elixir
# Via get options
{:ok, task} = Repo.Tasks.get(task_id, preloads: [:sections, :project])

# Via get_by
{:ok, task} = Repo.Tasks.get_by(conditions: [short_id: "x123"], preloads: [:sections])

# Explicit after fetch
task = Repo.preload(task, [:sections, project: [:users]])

# Force reload (ignore cached)
task = Repo.preload(task, :sections, force: true)
```

## Broadcaster Integration

The `Sacrum.Repo.Broadcaster` module provides a pass-through broadcasting pattern:

```elixir
# Pipe repo result through broadcast
def insert(project, attrs) do
  %Task{project_id: project.id}
  |> Task.create_changeset(attrs)
  |> Repo.insert()
  |> Broadcaster.broadcast(:task_created, :project)
end
```

The second argument is the event name. The third is the preload path to extract `project_id`:
- `:project` — entity has a `project_id` field directly
- `workflow: :project` — entity → workflow → project (nested preload)

See [Error Handling](error-handling.md) for how the Broadcaster handles failures.

## SyncHelper for Bulk Operations

`Sacrum.Repo.SyncHelper` provides a generic diff-and-sync pattern for managing sets of records atomically (used for workflow transitions, step transitions):

```elixir
SyncHelper.diff_and_sync(existing_records, incoming_maps, %{
  target_key: :to_workflow_id,
  to_delete_fn: fn existing, incoming_ids -> ... end,
  to_insert_fn: fn incoming, existing_by_target -> ... end,
  to_update_fn: fn incoming, existing_by_target -> ... end,
  build_changeset_fn: fn map -> ... end,
  build_update_changeset_fn: fn existing_rec, map -> ... end,
  fetch_final_fn: fn -> ... end
})
```

It compares existing DB records against incoming maps, determines inserts/updates/deletes, runs them in a single `Ecto.Multi` transaction, then fetches the final state.

## Advanced Query Patterns

### Recursive CTEs for Graph Traversal

Task dependencies use recursive CTEs for blocker resolution and path finding:

```elixir
# Blocker tree
def get_blockers(%Task{} = task) do
  base_query = from(d in TaskDependency,
    where: d.task_id == ^task.id,
    select: %{id: d.depends_on_id}
  )

  recursive_query = from(d in TaskDependency,
    join: b in fragment("blockers"), on: d.task_id == b.id,
    select: %{id: d.depends_on_id}
  )

  from(t in Task)
  |> with_cte("blockers", as: ^union_all(base_query, ^recursive_query))
  |> recursive_ctes(true)
  |> join(:inner, [t], b in fragment("blockers"), on: t.id == b.id)
  |> Repo.all()
end
```

### Raw SQL for Complex Path Finding

```elixir
def find_path(%Task{id: from_id}, %Task{id: to_id}) do
  sql = """
  WITH RECURSIVE path_search AS (
    SELECT depends_on_id AS current_id,
           ARRAY[$1::uuid, depends_on_id] AS path, 1 AS depth
    FROM task_dependencies WHERE task_id = $1::uuid
    UNION ALL
    SELECT d.depends_on_id, ps.path || d.depends_on_id, ps.depth + 1
    FROM task_dependencies d
    JOIN path_search ps ON d.task_id = ps.current_id
    WHERE NOT (d.depends_on_id = ANY(ps.path))
  )
  SELECT path FROM path_search WHERE current_id = $2::uuid
  ORDER BY depth LIMIT 1
  """

  {:ok, from_bin} = Ecto.UUID.dump(from_id)
  {:ok, to_bin} = Ecto.UUID.dump(to_id)

  case Ecto.Adapters.SQL.query(Repo, sql, [from_bin, to_bin]) do
    {:ok, %{rows: [[path]]}} -> {:ok, Enum.map(path, &Ecto.UUID.cast!/1)}
    {:ok, %{rows: []}} -> {:ok, []}
  end
end
```

## Naming Conventions

### Modules

- **Entity repos** — Plural noun: `Tasks`, `Workflows`, `Users`
- **Relationship repos** — Compound noun: `TaskDependencies`, `TaskHierarchy`, `StepTransitions`
- **Cross-domain repos** — Entity + domain: `TaskWorkflows` (workflow operations on tasks)
- **Support modules** — Descriptive noun: `Broadcaster`, `SyncHelper`

### Functions

| Prefix | Meaning | Example |
|--------|---------|---------|
| `list_*` | Query returning `[record]` | `list_tasks/1`, `list_for_project/1` |
| `get_*` | Specialized getter | `get_current_step/1`, `get_direct_blockers/1` |
| `find_*` | Search/path-finding | `find_path/2` |
| `add_*` / `remove_*` | Relationship management | `add_dependency/2` |
| `maybe_*` | Conditional operation | `maybe_update_parent/2` |
| `validate_*` | Validation helper | `validate_section_ownership/2` |
| `apply_*` | Query composition | `apply_filters/2` |
| `broadcast_*` | Event broadcasting | `broadcast_event/3` |
