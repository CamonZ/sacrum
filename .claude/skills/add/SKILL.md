---
name: add
description: Create a new task in vertebrae
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

# Assign to a workflow on creation
vtb add "Task" --workflow <workflow-id>
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
| `--workflow` | Workflow ID to assign task to |

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

## Next steps: add sections before triage

`vtb add` only creates the task shell. The `-d/--description` field is a free-form summary — **do not** stuff goals, checklist items, constraints, or testing criteria into it. Add those as sections with `/section` so they can be queried, indexed, and validated at triage.

**Required sections (block triage):**
- `goal` or `desired_behavior` — at least 1
- `checklist_item` — at least 1 implementation item
- `constraint` — at least 2
- `testing_criterion` — at least 2 (mix of unit + integration)

**Encouraged (warns, allows with `--force`):**
- `anti_pattern` — what to avoid
- `failure_test` — expected error/edge cases

**Optional context:**
- `context`, `current_behavior`

See `/section` and `docs/vtb/sections-and-triage.md` for the full list and triage rules.
