---
name: ready
description: Show actionable items ready for work or triage
---

# /ready

Show the highest-level unblocked items that are ready for work or triage.

## When to use
- Starting a work session — seeing what's actionable
- Finding the next thing to triage or pick up

## Command

```bash
vtb ready
```

## Output

```
Ready:
  a1b2c3  epic    New Feature Epic
  d4e5f6  ticket  Standalone Improvement
```

## How it works

Returns unblocked tasks (no pending dependency blockers) that are actionable — either ready for triage or ready to be picked up. Items are displayed with their ID, level, and title.

## See Also

- `/list` - Full task listing with filtering
- `/blockers` - See what blocks a specific task
