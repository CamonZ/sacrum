---
name: section
description: Add structured content to tasks
---

# /section

Add structured content to tasks. Sections are the canonical place for ticket content — prefer them over stuffing prose into `-d/--description`.

## Add sections

```bash
vtb section <task-id> <type> "content"
```

Use `--` to pass content that begins with `-`:

```bash
vtb section <task-id> constraint -- "--no-verify must never be used"
```

## Section types

**Single-instance** (re-running replaces the existing entry):

| Type | Use for |
|------|---------|
| `goal` | What this task achieves |
| `context` | Background information |
| `current_behavior` | How it works now (for bugs/changes) |
| `desired_behavior` | How it should work |

**Multi-instance** (each call appends a new entry):

| Type | Use for |
|------|---------|
| `checklist_item` | Ordered implementation steps / trackable checklist with done/undone |
| `constraint` | Requirements/limitations |
| `testing_criterion` | How to verify success |
| `anti_pattern` | What to avoid |
| `failure_test` | Expected failure/edge cases |

## Examples

```bash
vtb section abc123 goal "Implement user authentication"
vtb section abc123 checklist_item "Add User schema and migration"
vtb section abc123 checklist_item "Create login mutation"
vtb section abc123 constraint "Must use bcrypt for passwords"
vtb section abc123 constraint "No mocking the database in tests"
vtb section abc123 testing_criterion "Login returns JWT token"
vtb section abc123 testing_criterion "Invalid password returns 401"
```

## Triage requirements

A ticket cannot transition out of backlog until sections satisfy:

| Section | Minimum |
|---------|---------|
| `goal` or `desired_behavior` | 1 |
| `checklist_item` | 1 |
| `constraint` | 2 |
| `testing_criterion` | 2 (≥1 unit + ≥1 integration) |

`anti_pattern` and `failure_test` warn but allow with `--force`. See `docs/vtb/sections-and-triage.md`.

## View / edit / remove

```bash
vtb sections <task-id>                                       # List all
vtb sections <task-id> --type checklist_item                 # Filter by type
vtb update <task-id> --edit-section checklist_item 0 "..."   # Edit by ordinal (0-based)
vtb update <task-id> --remove-section checklist_item 0       # Remove by ordinal
vtb unsection <task-id> goal                                 # Remove single-instance
vtb unsection <task-id> checklist_item --index 2             # Remove multi-instance by ordinal
```
