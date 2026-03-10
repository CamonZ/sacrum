---
name: check-item
description: Mark a checklist item as complete within a task
---

# /check-item

Mark a checklist item as complete within a task.

## When to use
- When you have completed a checklist item
- To track progress within a task
- For session recovery visibility

## Syntax

```bash
vtb check-item <task-id> <item-index>
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `task-id` | Yes | Task ID containing the checklist item |
| `item-index` | Yes | 1-based index of the checklist item to mark done |

## Examples

```bash
# Mark checklist item 1 as done
vtb check-item abc123 1

# Mark checklist item 3 as done
vtb check-item abc123 3
```

## Viewing Checklist Item Status

Use `vtb show` to see checklist item completion status:

```bash
vtb show abc123
```

Checklist items display with checkboxes:
```
Checklist Items:
  1. [x] Create database schema
  2. [ ] Implement API endpoint
  3. [ ] Write tests
```

## Notes

- Item indices are 1-based (first item is 1, not 0)
- Task ID lookup is case-insensitive
- Only checklist items (added via `vtb section <task> checklist_item "..."`) can be checked
- Checking an item updates the task's `updated_at` timestamp

## Related Commands

- `vtb uncheck-item <task> <item-index>` - Uncheck a checklist item
- `vtb section <task> checklist_item "content"` - Add a checklist item to a task
- `vtb show <task>` - View task with checklist item completion status
- `vtb sections <task> --type checklist_item` - List all checklist items for a task
