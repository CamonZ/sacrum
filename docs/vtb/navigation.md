# Navigation: Transitions and Step Lifecycle

## Transitioning

```bash
vtb transition-to <id> backlog              # By step name
vtb transition-to <id> <step-uuid>          # By UUID
vtb transition-to <id> <target> --force     # Force past warnings
vtb transition-to <id> <target> --skip-validation  # Bypass entirely
```

## Cross-Workflow Transitions

```bash
vtb workflow transition add <from-wf> <to-wf> --label "approve"
vtb workflow transition add <from-wf> <to-wf> --label "escalate" --target-step <step-id>
vtb workflow transition list
vtb workflow transition delete <id>
```

## Step Lifecycle

| Command | Purpose |
|---------|---------|
| `vtb start-step <id>` | Mark current step as actively being worked on |
| `vtb complete-step <id>` | Mark current step as done |
| `vtb reject-step <id> <target> [-f "..."]` | Reject and move to target step with feedback |

## Working Through a Workflow

Given steps: Coding (0) -> Testing (1) -> Review (2, final):

```bash
# 1. Check current position
vtb show <id>

# 2. Work on current step
vtb start-step <id>
# ... do the work ...
vtb complete-step <id>

# 3. Move to next step
vtb transition-to <id> testing

# 4. Repeat until final step
vtb start-step <id>
vtb complete-step <id>
vtb transition-to <id> review
vtb start-step <id>
vtb complete-step <id>    # Final step — workflow complete
```

## Handling Rejections

```bash
# Reviewer finds issues
vtb reject-step <id> <coding-step-id> -f "Missing error handling for invalid contracts"
# Task returns to Coding step with feedback attached
```

## Completing a Ticket (Shortcut)

To mark a ticket as fully done:

```bash
vtb workflow assign <ticket-id> d3863c56-997b-486a-a663-fd8d4ed8d9bc
vtb start-step <ticket-id>
vtb complete-step <ticket-id>
```

Done workflow ID: `d3863c56-997b-486a-a663-fd8d4ed8d9bc`

## Marking Checklist Items Done

```bash
vtb check-item <task-id> 1    # Mark checklist item 1 as done
vtb show <task-id>            # View completion status
```

## Key Rules

- **`transition-to`** moves to any step within the same workflow (by name or UUID)
- **`start-step` / `complete-step` / `reject-step`** manage lifecycle within the current step
- **Never use `vtb update`** for workflow/step changes in a task — always use `transition-to` for intra workflow step changes or `workflow assign` for inter workflow changes
