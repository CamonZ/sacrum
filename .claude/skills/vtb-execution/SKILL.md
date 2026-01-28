---
name: Workflow Execution
description: Manage workflow execution history
user-invocable: true
allowed-tools: ["Bash"]
---

# /execution

Manage workflow execution records and session logs. Tracks the history of workflow step executions for audit and debugging.

## Subcommands

| Command | Description |
|---------|-------------|
| `execution create` | Create a new execution record |
| `execution list` | List executions for a task |
| `execution show` | Show execution details |
| `execution update` | Update execution status |
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
Executions for task abc123:
ID        Step      Status      Created
----------------------------------------------
a1b2c3    coding    completed   2024-01-15 10:30
d4e5f6    coding    failed      2024-01-15 09:15
g7h8i9    review    running     2024-01-15 11:00
```

---

## execution show

Show detailed execution information.

```bash
vtb execution show <execution-id>
```

Output:
```
Execution: a1b2c3
============================================================

Task: abc123
Workflow: implementation
Step: coding
Status: completed

Context
----------------------------------------
{"user": "alice", "environment": "staging"}

Session Logs
----------------------------------------
[10:30:15] INFO: Starting code review
[10:32:45] INFO: Found 3 issues
[10:35:00] INFO: Review complete
```

---

## execution update

Update execution status.

```bash
vtb execution update <execution-id> --status completed
vtb execution update <execution-id> --status failed
```

---

## execution log

Add a log entry to an execution.

```bash
vtb execution log <execution-id> "Processing file auth.rs"

# With log level
vtb execution log <execution-id> "Found syntax error" --level error
vtb execution log <execution-id> "Starting analysis" --level info
```

### Options

| Flag | Description |
|------|-------------|
| `--level` | Log level: debug, info, warn, error |

---

## Execution Lifecycle

1. **Create**: `vtb execution create` when starting work on a step
2. **Log**: `vtb execution log` to record progress
3. **Update**: `vtb execution update` to mark completion/failure

## When to Use

- Tracking automated workflow progress
- Debugging failed executions
- Auditing workflow history
- Recording agent interactions
