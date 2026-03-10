---
name: uncheck-item
description: Uncheck a checklist item within a task
---

# /uncheck-item

Uncheck a previously completed checklist item within a task, marking it as not done.

## When to use
- When a checklist item needs to be revisited or redone
- To correct a mistakenly checked item
- When requirements change and a checklist item is no longer complete

## Syntax

```bash
vtb uncheck-item <task-id> <item-index>
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `task-id` | Yes | Task ID containing the checklist item |
| `item-index` | Yes | 1-based index of the checklist item to uncheck |

## Examples

```bash
# Uncheck checklist item 1
vtb uncheck-item abc123 1

# Uncheck checklist item 3
vtb uncheck-item abc123 3
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
- Only checklist items (added via `vtb section <task> checklist_item "..."`) can be unchecked
- Unchecking an item updates the task's `updated_at` timestamp

## Related Commands

- `vtb check-item <task> <item-index>` - Check a checklist item as done
- `vtb section <task> checklist_item "content"` - Add a checklist item to a task
- `vtb show <task>` - View task with checklist item completion status
- `vtb sections <task> --type checklist_item` - List all checklist items for a task
