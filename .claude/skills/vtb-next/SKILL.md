---
name: Next Task
description: Complete current task and move to the next one
user-invocable: true
allowed-tools: ["Bash"]
---

# /next

Complete current task and move to the next one.

## When to use
- After finishing implementation of a task
- To see what was unblocked
- To start the next task in sequence

## Commands

```bash
# Mark current task done (shows unblocked tasks)
vtb transition-to <task-id> done

# Start the next task
vtb transition-to <next-task-id> in_progress

# If unsure what to work on, check blockers of your goal
vtb blockers <goal-task-id>
```
