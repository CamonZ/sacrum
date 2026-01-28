---
name: Update Task
description: Modify existing task fields
user-invocable: true
allowed-tools: ["Bash"]
---

# /update

Modify existing task fields.

## Usage

```bash
# Update title
vtb update <task-id> --title "New title"

# Update description
vtb update <task-id> --description "New description"

# Change priority
vtb update <task-id> --priority high

# Add tags (can specify multiple)
vtb update <task-id> --add-tag urgent --add-tag backend

# Remove tags (can specify multiple)
vtb update <task-id> --remove-tag old-tag

# Change level
vtb update <task-id> --level ticket

# Set or change parent
vtb update <task-id> --parent <parent-id>

# Remove parent (orphan the task)
vtb update <task-id> --parent ""

# Edit a section inline
vtb update <task-id> --edit-section step 0 "Updated step content"

# Remove a section inline
vtb update <task-id> --remove-section step 0
```

## Options

| Flag | Description |
|------|-------------|
| `--title` | New task title |
| `-d, --description` | New description (use "" to clear) |
| `-p, --priority` | Priority: low, medium, high, critical |
| `--add-tag` | Add a tag (repeatable) |
| `--remove-tag` | Remove a tag (repeatable) |
| `--parent` | Set parent task (use "" to remove) |
| `--edit-section` | Edit section: `<type> <ordinal> <content>` |
| `--remove-section` | Remove section: `<type> <ordinal>` |

## Note
For status changes, use the transition command:
```bash
vtb transition-to <task-id> <workflow>
vtb transition-to <task-id> <workflow>:<step>
```

## Important
NEVER use update for status changes - use `transition-to` instead
