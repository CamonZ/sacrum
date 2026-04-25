# Sections and Triage

## Section Types

| Type | Purpose | Cardinality |
|------|---------|-------------|
| `goal` | What this task achieves | Single |
| `context` | Background information | Single |
| `current_behavior` | How it works now (for bugs) | Single |
| `desired_behavior` | How it should work | Single |
| `step` | Ordered implementation steps | Multiple |
| `checklist_item` | Trackable checklist with done/undone | Multiple |
| `constraint` | Requirements/limitations | Multiple |
| `testing_criterion` | How to verify success | Multiple |
| `anti_pattern` | What to avoid | Multiple |
| `failure_test` | Expected failure/edge cases | Multiple |

## Adding Sections

```bash
vtb section <id> goal <TASK_GOAL>
vtb section <id> context <TASK_CONTEXT> 
vtb section <id> checklist_item <CHECKLIST_ITEM_1>
vtb section <id> checklist_item <CHECKLIST_ITEM_2>
vtb section <id> constraint <CONSTRAINT_1>
vtb section <id> constraint <CONSTRAINT_2>
vtb section <id> testing_criterion <TESTING_CRITERION_1>
vtb section <id> testing_criterion <TESTING_CRITERION_2>
vtb section <id> anti_pattern <ANTI_PATTERN_TO_NOT_FOLLOW>
vtb section <id> failure_test <ASSERTIONS_THAT_SHOULD_BE_REFUTED_TO_PASS>
```

## Viewing, Editing, and Removing Sections

```bash
vtb sections <id>                              # List all sections
vtb sections <id> --type step                  # Filter by type
vtb update <id> --edit-section step 0 "Updated content"
vtb update <id> --remove-section step 0
vtb unsection <id> goal                        # Remove single-instance type
vtb unsection <id> step --index 2              # Remove multi-instance type
```

## Checklist Items

```bash
vtb check-item <id> 1       # Mark checklist item #1 as done
vtb uncheck-item <id> 2     # Uncheck item #2
vtb show <id>               # View checklist status
```

## Triage: Making Tickets Ready for Work

Triage validates that a ticket is properly documented before it can be transitioned into an actionable workflow.

### Required Sections (blocks triage)

| Section | Minimum | Details |
|---------|---------|---------|
| `testing_criterion` | **2** | At least 1 unit + 1 integration |
| `step` | **1** | Implementation steps |
| `constraint` | **2** | Architectural/quality guidelines |
| `goal` or `desired_behavior` | **1** | Clear objective |

### Encouraged (warns, allows with `--force`)

| Section | Minimum |
|---------|---------|
| `anti_pattern` | **1** |
| `failure_test` | **1** |

### Triage Commands

```bash
vtb show <id>                                       # Check what's missing
vtb transition-to <id> <target-step>                # Validates sections
vtb transition-to <id> <target-step> --force        # Force past warnings
vtb transition-to <id> <target-step> --skip-validation  # Bypass entirely
```
