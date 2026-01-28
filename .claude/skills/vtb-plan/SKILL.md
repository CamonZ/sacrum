---
name: Plan
description: Create an implementation plan for a complex task using vertebrae
user-invocable: true
allowed-tools: ["Bash", "Read", "Glob", "Grep"]
---

# /plan

Create an implementation plan for a complex task using vertebrae.

## When to use
- Starting work on a feature, refactor, or multi-step task
- When you need to break down work into dependent steps
- Before writing code for non-trivial changes

## Hierarchy

```
epic           Large initiative
  └── ticket   Deliverable feature
        └── task      Unit of work
```

## Steps

1. Create an epic for the overall effort:
   ```bash
   vtb add "<initiative title>" -l epic -d "<description>"
   ```

2. Explore the codebase to understand scope and identify affected areas

3. Break into tickets (deliverables):
   ```bash
   vtb add "<feature 1>" -l ticket --parent <epic-id>
   vtb add "<feature 2>" -l ticket --parent <epic-id>
   ```

4. Break tickets into tasks (units of work):
   ```bash
   vtb add "<task 1>" --parent <ticket-id>
   vtb add "<task 2>" --parent <ticket-id>
   ```

5. Set dependencies between tasks:
   ```bash
   vtb depend <task-id> --on <blocker-id>
   ```

6. Add implementation details:
   ```bash
   vtb section <task-id> step "<step description>"
   vtb section <task-id> constraint "<constraint>"
   vtb section <task-id> testing_criterion "<how to verify>"
   vtb ref <task-id> "path/to/file.rs:L<line>" --name "<description>"
   ```

7. Show the plan:
   ```bash
   vtb show <epic-id>
   vtb blockers <final-task-id>
   ```

8. Start the first unblocked task:
   ```bash
   vtb transition-to <task-id> in_progress
   ```
