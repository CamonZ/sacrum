---
name: archive
description: Archive or unarchive tasks to hide them from default listings
---

# /archive

Archive or unarchive tasks. Archived tasks are hidden from `vtb list` by default, useful for decluttering completed or deferred work without deleting it.

## Usage

```bash
# Archive a task
vtb archive <task-id>

# Unarchive a task
vtb unarchive <task-id>
```

## Behavior

- `vtb archive <id>` sets `archived=true` on the task
- `vtb unarchive <id>` sets `archived=false` on the task
- Archived tasks are hidden from `vtb list` output by default
- Use `vtb list --include-archived` to show archived tasks alongside active ones

## When to Use

- Hide completed work that no longer needs attention
- Declutter task listings without permanently deleting tasks
- Temporarily shelve tasks that are deferred or on hold
- Restore previously archived tasks when work resumes
