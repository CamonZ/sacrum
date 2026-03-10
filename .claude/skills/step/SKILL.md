---
name: step
description: Manage workflow steps
---

# /step

Manage first-class workflow steps. Steps define the stages a task moves through within a workflow.

## Subcommands

| Command | Description |
|---------|-------------|
| `step add` | Create a new step for a workflow |
| `step list` | List all steps for a workflow |
| `step show` | Show step details |
| `step update` | Update step properties |
| `step delete` | Delete a step |

---

## step add

Create a new step for a workflow.

```bash
# Basic step
vtb step add "Review" -w <workflow-id>

# With goal and model
vtb step add "Coding" -w <workflow-id> --goal "Implement the feature" --model sonnet

# With agents and skills
vtb step add "Testing" -w <workflow-id> \
  --agent .claude/agents/test-runner.md \
  --skill run-tests \
  --skill check-coverage

# With transitions and final flag
vtb step add "Approved" -w <workflow-id> --final
vtb step add "Needs Work" -w <workflow-id> --transition-to <step-id>
```

### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--workflow` | `-w` | Workflow ID (required) |
| `--goal` | `-g` | Goal describing what this step accomplishes |
| `--agent` | `-a` | Path to agent file (repeatable) |
| `--skill` | `-s` | Skill name (repeatable) |
| `--model` | `-m` | Model to use |
| `--order` | `-o` | Step order (default: 0) |
| `--final` | | Mark as a final step |
| `--transition-to` | `-t` | Steps this can transition to (repeatable) |

---

## step list

List all steps for a workflow.

```bash
vtb step list <workflow-id>
```

Output:
```
Steps for workflow '<workflow-id>':
1. coding (id: a1b2c3d4, model: sonnet)
2. testing (id: e5f6a7b8, model: haiku)
3. documentation (id: c9d0e1f2, model: haiku)
```

---

## step show

Show detailed step information.

```bash
vtb step show <step-id>
```

Output shows step ID, name, workflow, order, goal, agents, skills, transitions, and timestamps in a flat key-value format.

---

## step update

Update step properties.

```bash
# Update goal
vtb step update <step-id> --goal "New goal description"

# Change model
vtb step update <step-id> --model opus

# Replace agents list (replaces entire list, not additive)
vtb step update <step-id> --agent .claude/agents/reviewer.md

# Clear all agents
vtb step update <step-id> --clear-agents

# Clear all skills
vtb step update <step-id> --clear-skills

# Clear all transitions
vtb step update <step-id> --clear-transitions

# Change order
vtb step update <step-id> --order 1
```

---

## step delete

Delete a step.

```bash
vtb step delete <step-id>

# Force delete without confirmation
vtb step delete <step-id> --force
```

---

## Step Concepts

### Order
Steps are ordered by their `order` field. Lower values execute first.

### Final Steps
Steps marked `--final` represent completion states. When a task reaches a final step, the workflow is considered complete.

### Transitions
By default, steps can transition to any other step. Use `--transition-to` to restrict valid transitions.

### Agents
Steps can have associated agent files that provide prompts and configuration for AI-assisted execution.

### Skills
Steps can reference skills (slash commands) available during that step.
