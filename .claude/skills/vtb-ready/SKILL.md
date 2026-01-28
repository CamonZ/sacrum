---
name: Ready
description: Show highest-level actionable items ready for work or triage
user-invocable: true
allowed-tools: ["Bash"]
---

# /ready

Show highest-level actionable items ready for work or triage.

## When to use
- Starting a work session - "What can I work on?"
- Finding what to triage next from backlog
- Understanding entry points into work streams

## Command

```bash
vtb ready
```

## Output

```
Ready to work (todo):
  f124c6  ticket  Define Workflow Schema

Ready to triage (backlog):
  a1b2c3  epic    New Feature Epic
  d4e5f6  ticket  Standalone Improvement
```

## How it works

Shows **highest-level entry points** in each hierarchy:

- **Todo section**: Unblocked items ready to start working on
- **Backlog section**: Unblocked items ready to triage to todo

### Hierarchy logic
- Shows epic if no children have started work
- Shows first unblocked child if parent work has begun
- Never shows both parent and child together

### Work started definition
A parent has "work started" if any child is in: `in_progress`, `pending_review`, or `done`

## Examples

```bash
# See what's ready
vtb ready

# Then start work on an item
vtb transition-to <task-id> in_progress

# Or triage a backlog item to make it available for work
vtb transition-to <task-id> todo
```
