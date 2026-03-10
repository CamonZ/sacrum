---
name: status
description: Check current task state and progress
---

# /status

Check current task state and progress.

## When to use
- Resuming a session
- Checking what's in progress
- Understanding what's blocked

## Commands

```bash
# List all tasks
vtb list

# Show tasks in progress
vtb list --status in_progress

# Show what's blocking a specific task
vtb blockers <task-id>

# Show full details of current task
vtb show <task-id>
```
