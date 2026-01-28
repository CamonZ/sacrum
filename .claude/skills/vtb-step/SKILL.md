---
name: Workflow Steps
description: Manage workflow steps
user-invocable: true
allowed-tools: ["Bash"]
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
vtb step add "Review" -w implementation

# With goal and model
vtb step add "Coding" -w impl --goal "Implement the feature" --model sonnet

# With agents and skills
vtb step add "Testing" -w impl \
  --agent .claude/agents/test-runner.md \
  --skill run-tests \
  --skill check-coverage

# With transitions and final flag
vtb step add "Approved" -w review --final
vtb step add "Needs Work" -w review --transition-to coding
```

### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--workflow` | `-w` | Workflow ID (required) |
| `--id` | | Custom step ID (auto-generated if not provided) |
| `--goal` | `-g` | Goal describing what this step accomplishes |
| `--agent` | `-a` | Path to agent file (repeatable) |
| `--skill` | `-s` | Skill name (repeatable) |
| `--model` | `-m` | Model to use (legacy) |
| `--order` | `-o` | Step order (default: 0) |
| `--final` | | Mark as a final step |
| `--transition-to` | `-t` | Steps this can transition to (repeatable) |

---

## step list

List all steps for a workflow.

```bash
vtb step list -w implementation
```

Output:
```
Steps for workflow: implementation
1. coding (order: 0) - model: sonnet
2. testing (order: 1) - model: haiku
3. documentation (order: 2) - model: haiku
```

---

## step show

Show detailed step information.

```bash
vtb step show coding
```

Output:
```
Step: coding
============================================================

Workflow: implementation
Order: 0
Final: No

Goal
----------------------------------------
Implement the feature according to specifications

Agent Config
----------------------------------------
Model: sonnet
Agents: .claude/agents/coder.md

Transitions To
----------------------------------------
- testing
- needs_work
```

---

## step update

Update step properties.

```bash
# Update goal
vtb step update coding --goal "New goal description"

# Change model
vtb step update coding --model opus

# Add/remove agents
vtb step update coding --add-agent .claude/agents/reviewer.md
vtb step update coding --remove-agent .claude/agents/old.md

# Change order
vtb step update coding --order 1
```

---

## step delete

Delete a step.

```bash
vtb step delete old-step
```

Note: Cannot delete steps that are currently in use by tasks.

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

## When to Use

- **step add**: Add new stages to an existing workflow
- **step list**: See all steps in a workflow
- **step show**: Understand what a step does
- **step update**: Modify step behavior
- **step delete**: Remove unused steps
