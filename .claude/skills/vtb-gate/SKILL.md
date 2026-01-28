---
name: Validation Gates
description: Manage validation gates for workflow steps
user-invocable: true
allowed-tools: ["Bash"]
---

# /gate

Manage validation gates that control step transitions. Gates define criteria that must be met before a task can progress.

## Subcommands

| Command | Description |
|---------|-------------|
| `gate create` | Create a new validation gate |
| `gate list` | List all gates |
| `gate show` | Show gate details |
| `gate update` | Update gate properties |
| `gate delete` | Delete a gate |

---

## gate create

Create a new validation gate.

```bash
# Command execution gate (exit code 0 = pass)
vtb gate create "Tests Pass" --type command

# Agent classification gate (LLM decides pass/fail)
vtb gate create "Code Quality" --type agent

# Manual approval gate
vtb gate create "Security Review" --type manual

# Composite gate (combine multiple gates)
vtb gate create "All Checks" --type composite
```

### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--type` | `-t` | Gate type: command, agent, manual, composite |
| `--workflow` | `-w` | Scope gate to a specific workflow |
| `--description` | `-d` | Gate description |

### Gate Types

| Type | Validation Method |
|------|-------------------|
| `command` | Run shell command, exit code 0 = pass |
| `agent` | LLM agent classifies result as pass/fail |
| `manual` | Requires explicit human approval |
| `composite` | Combines multiple gates with a mechanism |

---

## gate list

List all validation gates.

```bash
vtb gate list

# Filter by workflow
vtb gate list --workflow implementation
```

Output:
```
Gates:
ID          Type      Name              Workflow
-------------------------------------------------
gate_abc    command   Tests Pass        implementation
gate_def    manual    Security Review   (global)
gate_ghi    agent     Code Quality      review
```

---

## gate show

Show detailed gate information.

```bash
vtb gate show gate_abc
```

Output:
```
Gate: gate_abc
============================================================

Name: Tests Pass
Type: Command Execution
Workflow: implementation

Description
----------------------------------------
Runs the test suite and checks for passing tests

Configuration
----------------------------------------
Command: cargo test --quiet
Pass Condition: Exit code 0
```

---

## gate update

Update gate properties.

```bash
vtb gate update gate_abc --description "New description"
vtb gate update gate_abc --name "Updated Name"
```

---

## gate delete

Delete a gate.

```bash
vtb gate delete gate_abc
```

---

## Composite Gate Mechanisms

When creating composite gates, specify how sub-gates are evaluated:

| Mechanism | Description |
|-----------|-------------|
| `all` | All gates must pass |
| `any` | At least one gate must pass |
| `weighted` | Weighted voting with threshold |

```bash
vtb gate create "Release Ready" --type composite \
  --mechanism all \
  --gate tests_pass \
  --gate security_review
```

## When to Use

- Enforcing quality gates before progression
- Requiring manual approval for sensitive changes
- Running automated checks (tests, linting)
- Combining multiple validation criteria
