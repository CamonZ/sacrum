---
name: unref
description: Remove code references from a task
---

# /unref

Remove code references from a task by file path or remove all references.

## Usage

```bash
# Remove all references to a specific file
vtb unref <task-id> "src/auth.rs"

# Remove all references from the task
vtb unref <task-id> --all
```

## Flags

| Flag | Description |
|------|-------------|
| `--all` | Remove all references (conflicts with file argument) |

## Related commands

```bash
vtb ref <task-id> "src/file.rs:L42"    # Add a reference
vtb refs <task-id>                      # List all references
```
