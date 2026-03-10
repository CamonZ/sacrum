---
name: unsection
description: Remove sections from a task
---

# /unsection

Remove sections from a task by type and optionally by ordinal index.

## Usage

```bash
# Remove a single-instance section (goal, context, current_behavior, desired_behavior)
vtb unsection <task-id> goal
vtb unsection <task-id> context

# Remove a multi-instance section by ordinal (0-based index)
vtb unsection <task-id> checklist_item --index 2
vtb unsection <task-id> testing_criterion --index 1
```

## Flags

| Flag | Description |
|------|-------------|
| `--index`, `-i` | Remove specific section by ordinal (required for multi-instance types). Indices are 0-based. |

## Section types

**Single-instance** (no `--index` needed): goal, context, current_behavior, desired_behavior

**Multi-instance** (`--index` required): checklist_item, testing_criterion, anti_pattern, failure_test, constraint

## Related commands

```bash
vtb section <task-id> checklist_item "Do this"    # Add a section
vtb sections <task-id>                  # List all sections
```
