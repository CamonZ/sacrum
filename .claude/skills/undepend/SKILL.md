---
name: undepend
description: Remove a dependency between tasks
---

# /undepend

Remove a dependency relationship between tasks.

## Usage

```bash
# Task A no longer depends on task B
vtb undepend <task-a> --on <task-b>
```

## Behavior

- If the dependency exists, it is removed
- If the dependency does not exist, a warning is shown (not an error)

## Related commands

```bash
vtb depend <task-a> --on <task-b>    # Create dependency
vtb blockers <task-id>               # View dependency chain
vtb path <from> <to>                 # Find dependency path
```
