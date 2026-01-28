---
name: Add Task
description: Create a new task in vertebrae
user-invocable: true
allowed-tools: ["Bash"]
---

# /add

Create a new task in vertebrae.

## Usage

```bash
# Basic task
vtb add "Task title"

# With level and description
vtb add "Feature title" -l epic -d "Detailed description"

# As child of another task
vtb add "Subtask" --parent <parent-id>

# With dependencies
vtb add "Task" --depends-on <blocker-id>

# With priority and tags
vtb add "Urgent fix" -p critical -t bug -t backend

# Mark as needing human review
vtb add "Sensitive change" --needs-review
```

## Options

| Flag | Description |
|------|-------------|
| `-l, --level` | Task level: epic, ticket, task (default: task) |
| `-d, --description` | Detailed description |
| `-p, --priority` | Priority: low, medium, high, critical |
| `-t, --tag` | Add tag (repeatable) |
| `--parent` | Parent task ID |
| `--depends-on` | Blocker task ID (repeatable) |
| `--needs-review` | Mark as needing human review |

## Hierarchy (use in order)

```
epic       → tickets → tasks
```

| Level | When to use | Example |
|-------|-------------|---------|
| `epic` | Large initiative spanning multiple features | "Refactor auth system" |
| `ticket` | Single deliverable feature | "Implement JWT service" |
| `task` | Unit of work (default) | "Create sign() function" |

## Priorities
- `low`, `medium`, `high`, `critical`

## Next steps: Move to todo (triage)

After creating a ticket, you'll need to add structured content before it can be moved to `todo` status.

**Required sections to triage** (minimum to move from backlog → todo):
- `testing_criterion` - 2 minimum (at least 1 unit + 1 integration test)
- `step` - 1 minimum (implementation steps)
- `constraint` - 2 minimum (architectural guidelines + test quality rules)

**Strongly encouraged** (will warn but allow with `--force`):
- `anti_pattern` - What NOT to do / pitfalls to avoid
- `failure_test` - Expected error scenarios and failure cases

**Recommended** (informational notes):
- `goal` or `desired_behavior` - Clear objective
- `context` - Background information
- `current_behavior` - For bugs/changes (current state)

See `/triage` for complete workflow and examples of adding these sections.
