---
name: Show Task
description: Display full details of a task including sections, refs, and relationships
user-invocable: true
allowed-tools: ["Bash"]
---

# /vtb-show

Display full details of a task including sections, refs, and relationships.

## Usage

```bash
vtb show <task-id>
```

## Output includes
- Task metadata (level, status, priority, tags)
- Sections (goals, steps, constraints, context)
- Code references
- Parent task
- Blocking and blocked-by relationships
