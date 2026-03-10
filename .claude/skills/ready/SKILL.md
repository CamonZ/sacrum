---
name: ready
description: Show unblocked backlog items ready for triage
---

# /ready

Show unblocked items in the backlog that are ready to be triaged.

## When to use
- Finding what to triage next from backlog
- Starting a work session — seeing what needs attention

## Command

```bash
vtb ready
```

## Output

```
Ready to start (backlog):
  a1b2c3  epic    New Feature Epic
  d4e5f6  ticket  Standalone Improvement
```

## How it works

Returns all unblocked tasks (no pending dependency blockers) that are in the backlog. Items are displayed with their ID, level, and title.

## See Also

- `/list` - Full task listing with filtering
- `/blockers` - See what blocks a specific task
