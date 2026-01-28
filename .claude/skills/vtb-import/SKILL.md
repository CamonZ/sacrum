---
name: Import Tasks
description: Import tasks and relationships from JSONL format
user-invocable: true
allowed-tools: ["Bash"]
---

# /import

Import tasks and relationships from JSONL (JSON Lines) format for restoration or migration.

## Usage

```bash
# Import from file
vtb import --input backup.jsonl
vtb import -i backup.jsonl

# Import from stdin
cat backup.jsonl | vtb import

# Skip existing tasks
vtb import -i backup.jsonl --skip-existing
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--input` | `-i` | Input file path (reads from stdin if not specified) |
| `--skip-existing` | | Skip tasks that already exist by ID |

## Input Format

Each line must be a valid JSON object with a `type` field:

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
Imported 42 tasks (3 skipped), 15 child_of relations, 8 depends_on relations
```

## Behavior

- Tasks are created with their original IDs
- Relationships are established after all tasks are imported
- With `--skip-existing`, tasks with matching IDs are not overwritten
- Without `--skip-existing`, existing tasks cause an error

## When to Use

- Restoring from backups
- Migrating data from another system
- Loading seed data
- Syncing between environments

## See Also

- `/export` - Export to JSONL format
