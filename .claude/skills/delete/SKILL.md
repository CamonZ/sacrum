---
name: delete
description: Remove tasks from the database
---

# /delete

Remove tasks from the database.

## Usage

```bash
# Delete single task (prompts for confirmation)
vtb delete <task-id>

# Delete task and all children (cascade)
vtb delete <task-id> --cascade

# Force delete without prompts
vtb delete <task-id> --force

# Force cascade delete
vtb delete <task-id> --cascade --force
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--cascade` | | Delete the entire subtree (all children) |
| `--force` | `-f` | Skip all confirmation prompts |

## Behavior

When deleting a task with children (without `--cascade` or `--force`):
- Interactive prompt: `[C]ascade delete / [O]rphan / [A]bort`

With `--force` but without `--cascade`:
- Children are orphaned (become root tasks)

## Warnings
- Deleting a task removes its sections and refs
- `--cascade` deletes entire subtree
- Dependencies pointing to deleted tasks are removed
