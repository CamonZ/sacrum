---
name: review
description: Toggle the needs_human_review flag on a task
---

# /review

Toggle or set the `needs_human_review` flag on a task. Tasks marked for review require human approval before certain transitions.

## Usage

```bash
# Toggle the flag (true → false, false → true)
vtb review <task-id>

# Set to a specific value
vtb review <task-id> --set true
vtb review <task-id> --set false
```

## Options

| Flag | Description |
|------|-------------|
| `--set` | Set to specific boolean value instead of toggling |

## Output

```
Task abc123 marked as needing review
```

or

```
Task abc123 marked as not needing review
```

## When to Use

- Mark sensitive changes that need human oversight
- Flag tasks for manual verification before completion
- Indicate that automated workflows should pause for review
- Clear review flag after human approval

## In Task Display

Tasks needing review show in `vtb show` output:

```
Human Review: True
```

## Workflow Integration

When `needs_human_review` is true:
- Automated workflow advancement may pause
- GUI shows review indicator
- Human must explicitly approve or clear the flag
