---
name: complete-step
description: Complete a workflow step for a task
---

# /complete-step

Complete the current workflow step for a task. Marks the step as done and transitions to the next step.

## Usage

```bash
vtb complete-step <task-id>
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `task-id` | Yes | Task ID to complete the step for |

## Examples

```bash
# Complete the current step for a task
vtb complete-step abc12345-0000-4000-8000-000000000001
```

## Output

```
Completed step for task 'abc12345-0000-4000-8000-000000000001'
```

## When to Use

- After finishing work on a workflow step
- To signal successful completion and advance to the next step
- When all acceptance criteria for the step are met

## Notes

- Task ID must be a valid UUID
- Task ID lookup is case-insensitive
- The task must exist and have a workflow assigned with a current step
- The server handles transitioning to the next step automatically

## Related Commands

- `vtb start-step <task>` - Start the current step
- `vtb reject-step <task> <target-step>` - Reject the current step
- `vtb workflow advance <task>` - Advance to next workflow step
- `vtb show <task>` - View task details and current step
