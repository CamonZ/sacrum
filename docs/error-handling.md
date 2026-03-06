# Error Handling

Sacrum uses a layered error handling approach. Errors originate at the database/validation layer and propagate upward through repositories, the accounts layer, and finally GraphQL resolvers.

## Error Types

### 1. Changeset Errors (Validation)

Ecto changesets carry field-level validation errors. Returned as `{:error, %Ecto.Changeset{}}`.

```elixir
# From repo operations
{:error, changeset} = Tasks.insert(project, %{})
# changeset.errors => [title: {"can't be blank", [validation: :required]}]

# From Ecto.Multi failures
{:error, :operation_name, changeset, _changes_so_far}
```

Absinthe serializes changesets automatically:

```json
{
  "errors": [
    {
      "message": "title can't be blank",
      "path": ["createTask"]
    }
  ]
}
```

### 2. Domain-Specific Errors (Atoms)

Business rule violations return `{:error, atom}`:

| Error Atom | Source | Meaning |
|------------|--------|---------|
| `:not_found` | `GenericRepo.get/1` | Record doesn't exist |
| `:self_dependency` | `TaskDependencies.add_dependency/2` | Task depends on itself |
| `:circular_dependency` | `TaskDependencies.add_dependency/2` | Would create a cycle in the DAG |
| `:different_projects` | `TaskDependencies.add_dependency/2` | Tasks belong to different projects |
| `:different_workflows` | `StepTransitions.insert/2` | Steps belong to different workflows |
| `:no_workflow` | `TaskWorkflows.move_to_step/2` | Task has no workflow assigned |
| `:no_current_step` | `TaskWorkflows.move_to_step/2` | Task has no current step |
| `:step_not_found` | `TaskWorkflows` | Step doesn't exist in the workflow |
| `:no_transition` | `TaskWorkflows` | No valid transition path between steps |
| `:not_in_started_status` | `TaskWorkflows` | Step execution isn't in "started" status |

### 3. Business Logic Errors (Three-Tuple)

The accounts layer translates domain atoms into HTTP-friendly error tuples:

```elixir
{:error, :unprocessable_entity, "a task cannot depend on itself"}
{:error, :unprocessable_entity, "would create a circular dependency"}
{:error, :unprocessable_entity, "one or more dependencies not found"}
```

This translation happens in modules like `Sacrum.Accounts.Tasks`:

```elixir
case Enum.find(results, &match?({:error, _}, &1)) do
  {:error, :self_dependency} ->
    {:error, :unprocessable_entity, "a task cannot depend on itself"}
  {:error, :circular_dependency} ->
    {:error, :unprocessable_entity, "would create a circular dependency"}
  {:error, :not_found} ->
    {:error, :unprocessable_entity, "one or more dependencies not found"}
end
```

### 4. Authentication Errors

The `ApiAuthPlug` halts the connection with a 401 JSON response before reaching GraphQL:

```elixir
# In the plug
with {:ok, token} <- extract_token(conn),
     {:ok, user} <- Auth.verify_token(token) do
  # assign :current_user
else
  {:error, :missing_token} -> unauthorized(conn, "Missing authorization header")
  {:error, :invalid_format} -> unauthorized(conn, "Invalid authorization header format")
  {:error, :invalid} -> unauthorized(conn, "Invalid API token")
  {:error, :expired} -> unauthorized(conn, "API token has expired")
end

defp unauthorized(conn, message) do
  conn
  |> put_resp_content_type("application/json")
  |> send_resp(401, Jason.encode!(%{error: message}))
  |> halt()
end
```

Auth errors from `Sacrum.Auth.verify_token/1`:

| Return | Cause |
|--------|-------|
| `{:ok, user}` | Valid, non-expired token |
| `{:error, :invalid}` | Token hash not found in DB |
| `{:error, :expired}` | Token exists but `expires_at` is in the past |

## Error Propagation Flow

```
Database / Ecto
    │
    ▼
Repository Modules (Sacrum.Repo.*)
    │  Returns: {:error, changeset} or {:error, atom}
    ▼
Accounts Layer (Sacrum.Accounts.*)
    │  Translates: {:error, atom} → {:error, :status, "message"}
    ▼
GraphQL Resolvers
    │  Absinthe serializes errors to JSON
    ▼
Client (JSON response)
```

## Patterns

### `with` Chains for Validation Pipelines

The most common pattern for multi-step operations with early error returns:

```elixir
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

When any clause returns `{:error, _}`, the `with` short-circuits and returns that error.

**Single-step `with` is an antipattern.** If you only have one clause, use `case` instead:

```elixir
# Bad — unnecessary with for a single match
with {:ok, project} <- Projects.get(project_id) do
  {:ok, project}
end

# Good — use case for a single clause
case Projects.get(project_id) do
  {:ok, project} -> {:ok, project}
  {:error, _} = error -> error
end
```

### Guard Clauses for Pre-Conditions

Pattern match on function heads to reject invalid states before executing logic:

```elixir
def move_to_step(%Task{workflow_id: nil}, _step_id), do: {:error, :no_workflow}
def move_to_step(%Task{current_step_id: nil}, _step_id), do: {:error, :no_current_step}

def move_to_step(%Task{} = task, step_id) do
  # ... actual logic
end
```

### Ecto.Multi Error Handling

See [Repository & Accounts Pattern — Ecto.Multi for Transactions](patterns.md#ectomulti-for-transactions) for the full Multi pattern including pre-transaction validation and error normalization.

### Programmatic Changeset Errors

For domain validations that aren't field-level, build a changeset with `add_error`:

```elixir
def sync_transitions(%Workflow{} = workflow, transition_maps) do
  target_ids = Enum.map(transition_maps, & &1["to_workflow_id"])

  if length(target_ids) != length(Enum.uniq(target_ids)) do
    changeset =
      %WorkflowTransition{}
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.add_error(:to_workflow_id, "duplicate to_workflow_id in transitions list")

    {:error, changeset}
  else
    do_sync_transitions(workflow, transition_maps)
  end
end
```

### Broadcaster Resilience

The Broadcaster intentionally swallows broadcast failures so mutations never fail due to broadcast issues:

```elixir
# Pass-through pattern
def broadcast({:ok, entity}, event, preload_path) do
  broadcast_event(entity, event, preload_path)
  {:ok, entity}
end

def broadcast({:error, _} = error, _event, _preload_path), do: error

# Extraction failure logs a warning but returns :ok
def broadcast_event(entity, event, preload_path) do
  case extract_project_id(entity, preload_path) do
    {:ok, project_id} ->
      # ... broadcast
    :error ->
      Logger.warning("[Broadcast] #{event} failed to extract project_id")
      :ok
  end
end
```

### GraphQL Resolver Pattern

Resolvers use `with` to chain authorization and data fetching:

```elixir
resolve(fn args, %{context: %{current_user: user}} ->
  project_id = Map.get(args, :project_id)

  with {:ok, _project} <- Accounts.Projects.get_by(user.id, conditions: [id: project_id]) do
    tasks = Accounts.Tasks.list_tasks(user.id, conditions: conditions)
    {:ok, tasks}
  end
end)
```

When `get_by` returns `{:error, :not_found}`, the `with` short-circuits and Absinthe converts the atom to a user-facing error message.

## Writing Error Handling

When adding new operations, follow these conventions:

1. **Repo modules** return `{:ok, result}` or `{:error, changeset | atom}`
2. **Domain rules** use specific atom errors (`:self_dependency`, not generic `:invalid`)
3. **Accounts layer** translates atoms to `{:error, :status, "human message"}`
4. **Pre-conditions** go in function head guards, not inside the function body
5. **Multi transactions** validate *before* building the Multi
6. **Broadcasts** are always after the operation succeeds, never inside the transaction
7. **No custom Absinthe middleware** — rely on default error serialization
