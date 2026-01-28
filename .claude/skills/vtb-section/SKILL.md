---
name: Sections
description: Add structured content to tasks
user-invocable: true
allowed-tools: ["Bash"]
---

# /section

Add structured content to tasks.

## Add sections

```bash
vtb section <task-id> <type> "content"
```

## Section types

| Type | Use for |
|------|---------|
| `goal` | What this task achieves |
| `context` | Background information |
| `current_behavior` | How it works now |
| `desired_behavior` | How it should work |
| `step` | Ordered implementation steps |
| `constraint` | Requirements/limitations |
| `testing_criterion` | How to verify success |
| `anti_pattern` | What to avoid |
| `failure_test` | Expected failure cases |

## Examples

```bash
vtb section abc123 goal "Implement user authentication"
vtb section abc123 step "Add User model"
vtb section abc123 step "Create login endpoint"
vtb section abc123 constraint "Must use bcrypt for passwords"
vtb section abc123 testing_criterion "Login returns JWT token"
```

## View/remove sections

```bash
vtb sections <task-id>              # List all
vtb unsection <task-id> --all       # Remove all
vtb unsection <task-id> --type step # Remove by type
```
