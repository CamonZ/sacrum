---
name: update
description: Modify existing task fields
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

# Set or change parent
vtb update <task-id> --parent <parent-id>

# Remove parent (orphan the task)
vtb update <task-id> --parent ""

# Edit a section inline
vtb update <task-id> --edit-section checklist_item 0 "Updated item content"

# Remove a section inline
vtb update <task-id> --remove-section checklist_item 0
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

For workflow transitions, use `vtb transition-to <task-id> <step-uuid>` or `vtb workflow assign`.
