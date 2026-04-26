---
name: transition-to
description: Transition a task to a specific workflow step
---

# /transition-to

Transition a task to a specific step within its current workflow. The target can be a step **name** (e.g., `backlog`, `coding`) or a step UUID.

## Usage

```bash
# By step name (most common)
vtb transition-to <task-id> backlog
vtb transition-to <task-id> coding

# By step UUID
vtb transition-to <task-id> <step-uuid>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `task-id` | Task UUID or 8-char short ID |
| `target` | Step name (within the task's current workflow) or step UUID |

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--force` | `-f` | Override warnings (but not errors) |
| `--skip-validation` | | Bypass workflow transition validation |

## Finding Step Names / UUIDs

```bash
vtb show <task-id>                   # Shows current workflow + step
vtb workflow show <workflow-id>      # See steps with their names and UUIDs
vtb step list <workflow-id>          # List steps with IDs
```

## Constraints

- The task must already be assigned to the same workflow as the target step
- To change workflows entirely, use `vtb workflow assign <task-id> <workflow-id>`
- Transitions are validated against the step's `transitions_to` graph unless `--skip-validation` is used

## Output

On success:
```
Transitioned task 'abc123' from implementation:coding to review:pending
```

When transitioning to a final step, unblocked tasks are shown:
```
Transitioned task 'abc123' from implementation:coding to implementation:done

Unblocked tasks:
  - def456 (Write unit tests)
  - ghi789 (Update documentation)
```

## See Also

- `/workflow assign` - Assign a workflow to a task (for cross-workflow moves)
- `/start-step` - Start the current step
- `/complete-step` - Complete the current step
