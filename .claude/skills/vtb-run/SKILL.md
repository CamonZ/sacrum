---
name: Run Workflow
description: Execute a workflow for a task via the GUI
user-invocable: true
allowed-tools: ["Bash"]
---

# /run

Execute a workflow for a task through the Tauri GUI. Sends a request to the GUI to begin workflow execution with visual progress tracking.

## Usage

```bash
vtb run <task-id>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `task-id` | Task ID with an assigned workflow |

## Requirements

1. Task must have a workflow assigned
2. GUI must be running on port 17273

## Output

```
✓ Workflow execution started for task abc123
  View progress in the GUI
```

## Errors

If the GUI is not running:
```
Failed to connect to GUI on port 17273. Is the GUI running?
```

If the task has no workflow:
```
Task abc123 has no assigned workflow
```

## How It Works

1. Validates task exists and has a workflow
2. Sends HTTP POST to `http://127.0.0.1:17273/api/run-workflow`
3. GUI receives request and begins execution
4. Progress is shown in the GUI interface

## When to Use

- Starting automated workflow execution
- Running agent-assisted workflows
- Executing multi-step processes with visual feedback

## See Also

- `/workflow assign` - Assign a workflow to a task
- `/workflow advance` - Manually advance to next step
- `/transition-to` - Direct status transitions
