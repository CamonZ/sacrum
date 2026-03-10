---
name: run
description: Execute a workflow step for a task via the daemon
---

# /run

Execute the current workflow step for a task. Sends a request to the Sacrum backend which broadcasts to the connected daemon for execution.

## Usage

```bash
vtb run <task-id>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `task-id` | Task ID with an assigned workflow and current step |

## Requirements

1. Task must have a workflow assigned
2. Task must have a current step set
3. A daemon must be connected to handle execution

## Output

```
Execution a1b2c3d4 started (step: review, status: in_progress)
```

## Errors

If no daemon is connected:
```
No daemon is connected to handle step execution. Start the daemon with `vtb-daemon` and try again.
```

If the task has no workflow:
```
Task abc123 has no assigned workflow
```

If the task has no current step:
```
Task abc123 has no current step. Assign a workflow first.
```

## How It Works

1. Validates task exists, has a workflow, and has a current step
2. Calls `run_step` on the Sacrum backend via GraphQL
3. Sacrum creates a `StepExecution` record and broadcasts to connected daemons
4. The daemon picks up the execution and runs the step

## When to Use

- Starting automated workflow execution
- Running agent-assisted workflows
- Executing multi-step processes

## See Also

- `/workflow assign` - Assign a workflow to a task
- `/start-step` - Start a workflow step
- `/complete-step` - Complete a workflow step
