---
name: reject-step
description: Reject a workflow step with optional feedback
---

# /reject-step

Reject the current workflow step for a task and transition to a target step, optionally providing feedback about the rejection.

## Usage

```bash
# Reject without feedback
vtb reject-step <task-id> <target-step-id>

# Reject with feedback
vtb reject-step <task-id> <target-step-id> --feedback "Reason for rejection"
```

## Arguments

| Argument | Required | Description |
|----------|----------|-------------|
| `task-id` | Yes | Task ID to reject the step for |
| `target-step-id` | Yes | Step ID to transition to (e.g., a previous step for revision) |

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--feedback` | `-f` | Feedback about why the step was rejected |

## Examples

```bash
# Reject and send back to a previous step
vtb reject-step abc12345-0000-4000-8000-000000000001 def67890-0000-4000-8000-000000000002

# Reject with feedback explaining what needs to change
vtb reject-step abc12345-0000-4000-8000-000000000001 def67890-0000-4000-8000-000000000002 \
  --feedback "Tests are failing, please fix before proceeding"
```

## Output

```
Rejected step for task 'abc12345-...' and transitioned to step 'def67890-...'
```

With feedback:
```
Rejected step for task 'abc12345-...' and transitioned to step 'def67890-...'. Feedback: Tests are failing, please fix before proceeding
```

## When to Use

- During review steps when the work doesn't meet criteria
- To send a task back to a previous step for rework
- When a step's output needs revision before it can proceed
- To provide actionable feedback on what needs to change

## Notes

- Both task ID and target step ID must be valid UUIDs
- ID lookup is case-insensitive
- The task must exist and have a workflow assigned
- Feedback is optional but recommended for clarity

## Related Commands

- `vtb start-step <task>` - Start the current step
- `vtb complete-step <task>` - Complete the current step
- `vtb workflow retreat <task>` - Retreat to previous workflow step
- `vtb show <task>` - View task details and current step
