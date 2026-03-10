---
name: execution
description: Manage workflow execution history
---

# /execution

Manage workflow execution records and session logs. Tracks the history of workflow step executions for audit and debugging.

## Subcommands

| Command | Description |
|---------|-------------|
| `execution create` | Create a new execution record |
| `execution list` | List executions for a task |
| `execution show` | Show execution details |
| `execution update` | Update execution output and result |
| `execution log` | Add a log entry to an execution |

---

## execution create

Create a new execution record for a task's current workflow step.

```bash
vtb execution create <task-id>

# With context and prompt data
vtb execution create abc123 \
  --context '{"user": "alice", "environment": "staging"}' \
  --prompt '{"instructions": "Review the code changes"}'
```

### Options

| Flag | Description |
|------|-------------|
| `--context` | JSON context data about the task |
| `--prompt` | JSON prompt data for the execution |

### Requirements

- Task must have a workflow assigned
- Creates execution for current workflow step

---

## execution list

List all executions for a task.

```bash
vtb execution list <task-id>
```

Output:
```
Executions for task abc123 (3 total)
============================================================
a1b2c3d4 | coding | COMPLETED    | 2024-01-15 10:30:45 -> 2024-01-15 10:32:30
d4e5f6a7 | coding | FAILED       | 2024-01-15 09:15:20 -> -
g7h8i9j0 | review | IN_PROGRESS  | 2024-01-15 11:00:15 -> -
```

---

## execution show

Show detailed execution information.

```bash
vtb execution show <execution-id>
```

---

## execution update

Update execution output and transition result.

```bash
vtb execution update <execution-id> --output "Review complete"
vtb execution update <execution-id> --transition_result advance
```

### Options

| Flag | Description |
|------|-------------|
| `--output` | Output text from the execution |
| `--transition_result` | Transition result (e.g., advance, reject, retry) |

---

## execution log

Add a log entry to an execution.

```bash
vtb execution log <execution-id> "Processing file auth.rs"
```

Takes a required content string as a positional argument.

---

## Execution Lifecycle

1. **Create**: `vtb execution create` when starting work on a step
2. **Log**: `vtb execution log` to record progress
3. **Update**: `vtb execution update` to set output and result

## When to Use

- Tracking automated workflow progress
- Debugging failed executions
- Auditing workflow history
- Recording agent interactions
