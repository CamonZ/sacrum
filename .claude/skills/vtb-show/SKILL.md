---
name: vtb-show
description: Display full details of a task including sections, refs, and relationships
---

# /vtb-show

Display full details of a task including sections, refs, and relationships.

## Usage

```bash
vtb show <task-id>
```

## Output includes
- Task metadata (level, priority, tags, human review flag, archived flag)
- Timestamps (started, updated, completed)
- Workflow assignment (name, current step, step progress)
- Worktree path (when set)
- Description
- All sections: goal, context, current_behavior, desired_behavior, checklist_items, testing_criteria, anti_patterns, failure_tests, constraints
- Code references (file paths with line numbers)
- Relationships: parent, children, blocked-by, blocks
- Revision feedback and rejection reason (when present)
