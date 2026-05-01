# Verbose Daemon Logging

The `verbose_daemon_logging` flag on `workflow_steps` is a diagnostic-only boolean that, when enabled, instructs the daemon to emit detailed tracing for that step's executions. This helps diagnose issues like:

- Whether `output_schema` arrives in the run_step payload
- Whether `output_schema` was successfully merged into `agent_config.json_schema` during build_step_config
- Whether `--json-schema` reached the CLI argv

The flag **cannot be set through createWorkflowStep or updateWorkflowStep GraphQL mutations**. Instead, it must be toggled out-of-band via:

1. Direct SQL UPDATE
2. iex Ecto.Changeset with the private setter

## SQL Toggle

Enable verbose logging for a specific step:

```sql
UPDATE workflow_steps
SET verbose_daemon_logging = true
WHERE id = '<step_uuid>';
```

Disable it:

```sql
UPDATE workflow_steps
SET verbose_daemon_logging = false
WHERE id = '<step_uuid>';
```

## iex Toggle

In an iex session with Sacrum loaded:

```elixir
# Fetch the step
{:ok, step} = Sacrum.Repo.WorkflowSteps.get("<step_uuid>")

# Enable verbose logging using the private setter
{:ok, updated_step} = Sacrum.Repo.WorkflowSteps.set_verbose_logging(step, true)

# Or disable it
{:ok, updated_step} = Sacrum.Repo.WorkflowSteps.set_verbose_logging(step, false)
```

Alternatively, using `Ecto.Changeset.change/2` directly to bypass the public allowlist:

```elixir
step
|> Ecto.Changeset.change(verbose_daemon_logging: true)
|> Sacrum.Repo.update()
```

## Broadcasting

When a step with `verbose_daemon_logging = true` is dispatched via `ExecutionDispatcher.create_and_dispatch`, the `run_step_payload` broadcast will include:

```json
{
  "id": "...",
  "task_id": "...",
  "prompt": "...",
  "agent_config": {...},
  "worktree": "...",
  "output_schema": {...},
  "verbose_daemon_logging": true
}
```

The `verbose_daemon_logging` field is **only included when true** for backward compatibility. Older daemon versions that don't yet know about this field will safely ignore it (serde with `#[serde(default)]` on the Rust side).

## GraphQL Regression Tests

The GraphQL mutations `createWorkflowStep` and `updateWorkflowStep` **must not** accept `verbose_daemon_logging` as an input argument, even for admin users. Regression tests verify this constraint:

- Calling `createWorkflowStep(..., verbose_daemon_logging: true, ...)` should be rejected by the schema or the step should have the flag as false.
- Calling `updateWorkflowStep(..., verbose_daemon_logging: true, ...)` should be rejected by the schema or the step should have the flag as false.
