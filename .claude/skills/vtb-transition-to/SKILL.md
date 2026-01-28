---
name: Transition
description: Transition a task to a workflow or workflow step
user-invocable: true
allowed-tools: ["Bash"]
---

# /transition-to

Transition a task to a specific workflow or workflow step. This is the primary command for changing task status.

## Usage

```bash
# Transition to a workflow (starts at first step)
vtb transition-to <task-id> <workflow>

# Transition to a specific step within a workflow
vtb transition-to <task-id> <workflow>:<step>

# Common transitions
vtb transition-to abc123 implementation        # Start implementation
vtb transition-to abc123 implementation:coding # Go to coding step
vtb transition-to abc123 review                # Move to review
vtb transition-to abc123 done                  # Mark complete
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--force` | `-f` | Override warnings (but not errors) |
| `--skip-validation` | | Bypass workflow transition validation |

## Target Format

The target can be specified in two formats:

1. **Workflow only**: `vtb transition-to <id> implementation`
   - Assigns the workflow and starts at its first step

2. **Workflow:Step**: `vtb transition-to <id> review:approved`
   - Transitions to a specific step within a workflow

## Output

On success, shows:
- Previous workflow/step (if any)
- New workflow/step
- List of tasks that are now unblocked

```
Transitioned abc123: backlog:todo → implementation:coding

Unblocked tasks:
  def456 - "Write unit tests"
  ghi789 - "Update documentation"
```

## Discover Available Workflows

**Before using `transition-to`, check configured workflows:**

```bash
vtb workflow list                    # List all workflows
vtb workflow show <workflow-id>      # See steps in a workflow
```

Workflow names and steps are project-specific. Always check what's available before transitioning.

## Example Workflows

These are examples — actual workflows depend on project configuration:

| Target | Description |
|--------|-------------|
| `backlog` | Initial state, needs triage |
| `todo` | Triaged, ready to work |
| `implementation` | Active development |
| `review` | Code review |
| `done` | Completed |

## When to Use

- Starting work on a task: `vtb transition-to <id> implementation`
- Completing a task: `vtb transition-to <id> done`
- Moving through workflow steps
- After finishing blockers to see what's unblocked

## transition-to vs workflow advance/retreat

| Command | Purpose |
|---------|---------|
| `vtb transition-to` | Move **across** workflows (e.g., `backlog` → `implementation`) |
| `vtb workflow advance` | Move to **next step** within current workflow |
| `vtb workflow retreat` | Move to **previous step** within current workflow |

**Use `transition-to` when:**
- Starting a new workflow (e.g., `backlog` → `implementation`)
- Jumping to a specific workflow:step (e.g., `review:approved`)
- Completing a task (`done`)

**Use `workflow advance/retreat` when:**
- Moving sequentially through steps within the same workflow
- Progressing from `coding` → `testing` → `documentation`

## Important

- `transition-to` is for cross-workflow moves
- `workflow advance/retreat` is for within-workflow moves
- Never use `vtb update` for status changes
- Transitions are validated against workflow rules
- Use `--skip-validation` only as an escape hatch
