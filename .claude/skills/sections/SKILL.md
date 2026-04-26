---
name: sections
description: List all sections for a task
---

# /sections

List all sections for a task, optionally filtered by type.

## Usage

```bash
# List all sections
vtb sections <task-id>

# Filter by type
vtb sections <task-id> --type checklist_item
vtb sections <task-id> --type testing_criterion
vtb sections <task-id> --type constraint
```

## Section types

**Single-instance:** `goal`, `context`, `current_behavior`, `desired_behavior`

**Multi-instance:** `checklist_item`, `constraint`, `testing_criterion`, `anti_pattern`, `failure_test`

See `/section` for the full type reference and triage requirements.

## Related commands

```bash
vtb section <task-id> checklist_item "Do this"     # Add a section
vtb unsection <task-id> goal                       # Remove single-instance
vtb unsection <task-id> checklist_item --index 2   # Remove multi-instance by ordinal
```
