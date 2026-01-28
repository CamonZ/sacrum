---
name: Export Tasks
description: Export tasks and relationships to JSONL format
user-invocable: true
allowed-tools: ["Bash"]
---

# /export

Export all tasks and relationships to JSONL (JSON Lines) format for backup or migration.

## Usage

```bash
# Export to stdout
vtb export

# Export to file
vtb export --output backup.jsonl
vtb export -o backup.jsonl
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--output` | `-o` | Output file path (defaults to stdout) |

## Output Format

Each line is a valid JSON object with a `type` field:

```jsonl
{"type":"task","id":"abc123","title":"My task","level":"task",...}
{"type":"child_of","child":"def456","parent":"abc123"}
{"type":"depends_on","task":"ghi789","blocker":"abc123"}
```

### Record Types

| Type | Description |
|------|-------------|
| `task` | Task data with all fields |
| `child_of` | Parent-child relationship |
| `depends_on` | Dependency relationship |

## Output Summary

```
Exported 42 tasks, 15 child_of relations, 8 depends_on relations to backup.jsonl
```

## When to Use

- Creating backups before major changes
- Migrating data between systems
- Sharing task data
- Version control of task state

## See Also

- `/import` - Import from JSONL format
