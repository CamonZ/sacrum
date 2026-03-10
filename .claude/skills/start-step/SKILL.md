---
name: start-step
description: Start a workflow step for a task
---

# /start-step

Start the current workflow step for a task. Signals that work on the step has begun.

## Usage

```bash
vtb start-step <task-id>
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `task-id` | Yes | Task ID to start the step for |

## Examples

```bash
# Start the current step for a task
vtb start-step abc12345-0000-4000-8000-000000000001
```

## Output

```
Started step for task 'abc12345-0000-4000-8000-000000000001'
```

## When to Use

- When beginning work on a workflow step
- To signal that a step is actively being worked on
- Before performing the implementation work for a step

## Notes

- Task ID must be a valid UUID
- Task ID lookup is case-insensitive
- The task must exist and have a workflow assigned with a current step

## Related Commands

- `vtb complete-step <task>` - Complete the current step
- `vtb reject-step <task> <target-step>` - Reject the current step
- `vtb workflow advance <task>` - Advance to next workflow step
- `vtb show <task>` - View task details and current step
