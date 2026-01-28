---
name: Step Done
description: Mark a step as complete within a task
user-invocable: true
allowed-tools: ["Bash"]
---

# /step-done

Mark a step as complete within a task.

## When to use
- When you have completed an implementation step
- To track progress within a task
- For session recovery visibility

## Syntax

```bash
vtb step-done <task-id> <step-index>
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `task-id` | Yes | Task ID containing the step |
| `step-index` | Yes | 1-based index of the step to mark done |

## Examples

```bash
# Mark step 1 as done
vtb step-done abc123 1

# Mark step 3 as done
vtb step-done abc123 3
```

## Viewing Step Status

Use `vtb show` to see step completion status:

```bash
vtb show abc123
```

Steps display with checkboxes:
```
Steps:
  1. [x] Create database schema
  2. [ ] Implement API endpoint
  3. [ ] Write tests
```

## Notes

- Step indices are 1-based (first step is 1, not 0)
- Task ID lookup is case-insensitive
- Only steps (added via `vtb section <task> step "..."`) can be marked done
- Marking a step done updates the task's `updated_at` timestamp

## Related Commands

- `vtb section <task> step "content"` - Add a step to a task
- `vtb show <task>` - View task with step completion status
- `vtb sections <task> --type step` - List all steps for a task
