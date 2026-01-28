---
name: Workflow
description: Manage workflows for task progression
user-invocable: true
allowed-tools: ["Bash"]
---

# /workflow

Manage workflows that define how tasks progress through steps.

**Start here to understand available workflows:**
```bash
vtb workflow list                    # See all configured workflows
vtb workflow show <workflow-id>      # See steps within a workflow
```

Workflow names and steps are project-specific. Always check what's configured before using `transition-to` or `workflow advance`.

## Subcommands

| Command | Description |
|---------|-------------|
| `workflow add` | Create a new workflow |
| `workflow list` | List all workflows |
| `workflow show` | Show workflow details |
| `workflow update` | Update workflow properties |
| `workflow delete` | Delete a workflow |
| `workflow assign` | Assign a task to a workflow |
| `workflow unassign` | Remove workflow from a task |
| `workflow advance` | Move task to next step |
| `workflow retreat` | Move task to previous step |
| `workflow reject` | Reject task (unassigns workflow) |

---

## workflow add

Create a new workflow with steps.

```bash
# Basic workflow with steps
vtb workflow add "Code Review" --step review:sonnet --step approved:haiku

# With description and auto-advance
vtb workflow add "CI Pipeline" \
  -d "Automated build and test" \
  --step build:haiku \
  --step test:sonnet \
  --auto-advance
```

### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--description` | `-d` | Workflow description |
| `--step` | `-s` | Step in `name:model` format (repeatable) |
| `--auto-advance` | | Auto-advance on completion |
| `--order` | `-o` | Display order (default: 0) |

---

## workflow list

List all defined workflows.

```bash
vtb workflow list
```

Output:
```
impl - Implementation (3 steps) - Standard development workflow
review - Code Review (2 steps)
deploy - Deployment (4 steps) - Production deployment pipeline
```

---

## workflow show

Show detailed workflow information.

```bash
vtb workflow show impl
```

Output:
```
Workflow: impl - Implementation
============================================================

Description
----------------------------------------
Standard development workflow

Auto Advance: No

Steps (3 total)
----------------------------------------
1. coding (model: sonnet)
2. testing (model: haiku)
3. documentation (model: haiku)
```

---

## workflow update

Update workflow properties.

```bash
# Update name
vtb workflow update impl --name "Development"

# Update description
vtb workflow update impl --description "New description"

# Clear description
vtb workflow update impl --clear-description

# Enable/disable auto-advance
vtb workflow update impl --auto-advance
vtb workflow update impl --no-auto-advance
```

### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--name` | `-n` | New workflow name |
| `--description` | `-d` | New description |
| `--clear-description` | | Remove description |
| `--auto-advance` | | Enable auto-advance |
| `--no-auto-advance` | | Disable auto-advance |

---

## workflow delete

Delete a workflow.

```bash
vtb workflow delete old-workflow
```

Note: Cannot delete workflows with assigned tasks.

---

## workflow assign

Assign a task to a workflow.

```bash
vtb workflow assign <task-id> <workflow-id>
```

Example:
```bash
vtb workflow assign abc123 implementation
# Output: Assigned task abc123 to workflow implementation at step 1: coding
```

---

## workflow unassign

Remove workflow assignment from a task.

```bash
vtb workflow unassign <task-id>
```

---

## workflow advance

Advance a task to the next workflow step.

```bash
vtb workflow advance <task-id>
```

Example:
```bash
vtb workflow advance abc123
# Output: Advanced task abc123: coding → testing (execution: a1b2c3)
```

---

## workflow retreat

Move a task back to the previous step.

```bash
vtb workflow retreat <task-id>
```

---

## workflow reject

Reject a task, removing its workflow assignment.

```bash
vtb workflow reject <task-id>
```

## When to Use

- **workflow add**: Define new task progression patterns
- **workflow assign**: Start a task on a workflow
- **workflow advance/retreat**: Navigate through steps **within** a workflow
- **transition-to**: Move **across** workflows (e.g., `backlog` → `implementation`)

## advance/retreat vs transition-to

| Command | Purpose |
|---------|---------|
| `workflow advance/retreat` | Move within current workflow (step to step) |
| `transition-to <workflow>` | Move across workflows |
| `transition-to <workflow>:<step>` | Jump to specific workflow and step |

**Example progression:**
```
backlog → implementation:coding → implementation:testing → review → done
        \_______ transition-to _______/
                 \___ advance ___/
```
