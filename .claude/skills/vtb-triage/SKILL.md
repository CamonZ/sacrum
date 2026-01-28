---
name: Triage
description: Triage a ticket from backlog to todo with validation
user-invocable: true
allowed-tools: ["Bash"]
---

# /triage

Move a ticket from backlog to todo, ensuring it's properly defined.

## When to use
- After refining a backlog ticket with all required sections
- When ready to make a ticket available for work
- After `vtb ready` shows backlog items to triage

## Command

```bash
vtb transition-to <task-id> todo
```

## Section requirements

### ✓ Required sections (blocks transition to todo)

These sections **must** be present and complete. Missing any will prevent moving from `backlog` → `todo`:

| Section | Minimum | Details |
|---------|---------|---------|
| `testing_criterion` | **2** | Must have at least 1 **unit test** criterion AND 1 **integration test** criterion. These define how to verify the implementation works. |
| `step` | **1** | Implementation steps describing HOW to build the feature. Should be ordered and actionable. |
| `constraint` | **2** | Architectural guidelines and test quality rules. Examples: "Use repository pattern", "No weak assertions in tests", "Must validate input at boundaries" |
| `goal` OR `desired_behavior` | **1** | Clear objective. Either a `goal` section OR a `desired_behavior` section (at least one required). |

### ⚠ Strongly encouraged (warnings allow override)

These sections will **warn** during triage but won't block the transition. Can be skipped with `--force` flag:

| Section | Minimum | Purpose |
|---------|---------|---------|
| `anti_pattern` | **1** | What NOT to do / pitfalls to avoid. Critical for preventing common mistakes. |
| `failure_test` | **1** | Expected error scenarios and edge cases. Describes how the code should fail gracefully. |

### ℹ Recommended (notes only, never blocks)

These sections provide valuable context but are informational only:

| Section | Purpose |
|---------|---------|
| `context` | Background information and why this work is needed |
| `current_behavior` | For bugs/changes: describes the current state before the fix |

## Adding sections

### Required sections first (to unblock triage):

```bash
# Define the goal/objective (1 required)
vtb section <id> goal "Allow users to search tasks by ID and content"

# Add testing criteria (2 minimum: 1 unit + 1 integration)
vtb section <id> testing_criterion "UNIT: Search filter returns only matching tasks"
vtb section <id> testing_criterion "INTEGRATION: GUI search box updates results in <500ms"

# Add implementation steps (1 minimum)
vtb section <id> step "Fix search query logic in TaskLister to match IDs and titles"
vtb section <id> step "Update GUI search handler to pass filter to backend"
vtb section <id> step "Add tests for search edge cases (partial matches, case sensitivity)"

# Add constraints (2 minimum)
vtb section <id> constraint "Must validate search input to prevent SQL injection"
vtb section <id> constraint "All tests must pass before moving to in_progress"
```

### Strongly encouraged (add if possible):

```bash
# Anti-patterns - what NOT to do
vtb section <id> anti_pattern "Don't concatenate search strings without parameterization"
vtb section <id> anti_pattern "Don't make search case-sensitive without user expectation"

# Failure tests - expected error scenarios
vtb section <id> failure_test "Empty search returns all tasks"
vtb section <id> failure_test "Special characters in search are escaped properly"
```

### Recommended context (add for clarity):

```bash
# Current behavior - for bug fixes
vtb section <id> current_behavior "Search in GUI list view returns no results for task IDs"

# Context - background information
vtb section <id> context "Users cannot find tasks by ID in the GUI, making task navigation difficult"
```

## Complete workflow

```bash
# 1. Create a new ticket
vtb add "Fix search bug" -l ticket -d "Search returns no results"

# 2. Check what sections are missing
vtb show <task-id>

# 3. Add all REQUIRED sections (these unblock the triage)
vtb section <task-id> goal "Enable searching tasks by ID and content"
vtb section <task-id> testing_criterion "UNIT: Search matches task IDs correctly"
vtb section <task-id> testing_criterion "INTEGRATION: GUI search filters display in real-time"
vtb section <task-id> step "Debug search query in backend TaskLister"
vtb section <task-id> step "Fix GUI search event handler"
vtb section <task-id> constraint "Must validate search input"
vtb section <task-id> constraint "All tests must pass"

# 4. Add STRONGLY ENCOURAGED sections (warnings but allow with --force)
vtb section <task-id> anti_pattern "Don't use raw search strings in queries"
vtb section <task-id> failure_test "Empty search returns all tasks"

# 5. Add RECOMMENDED context (optional but helpful)
vtb section <task-id> current_behavior "Search in list view returns no results"
vtb section <task-id> context "Users cannot navigate by task ID"

# 6. Verify all required sections are present
vtb show <task-id>

# 7. Triage: Move from backlog → todo
vtb transition-to <task-id> todo

# 8. Verify it's now in "ready to work" state
vtb ready
```

## Tips

- **Stuck on triage?** Run `vtb show <id>` to see exactly which sections are missing
- **Want to skip warnings?** Use `vtb transition-to <id> todo --force` (not recommended)
- **Need more time?** It's OK to leave tickets in backlog - only triage when truly ready
- **Each section needs content** - don't add empty/placeholder sections
