---
name: Dependency Path
description: Find the dependency path between two tasks
user-invocable: true
allowed-tools: ["Bash"]
---

# /path

Find the shortest dependency path between two tasks using breadth-first search.

## Usage

```bash
vtb path <from-task> <to-task>
```

## Arguments

| Argument | Description |
|----------|-------------|
| `from-task` | Source task ID |
| `to-task` | Target task ID |

## Output

If a path exists:
```
Dependency path from abc123 to xyz789:

abc123 "Deploy to production"
    ↓
def456 "Run integration tests"
    ↓
ghi789 "Fix failing tests"
    ↓
xyz789 "Update test fixtures"

Path length: 4 tasks
```

If no path exists:
```
No dependency path from abc123 to xyz789
```

## How It Works

- Traverses `depends_on` edges using BFS
- Finds the shortest path (fewest edges)
- Returns `None` if tasks are not connected

## When to Use

- Understanding why task A is blocked by task B
- Finding the critical path between milestones
- Debugging complex dependency chains
- Verifying expected dependencies exist

## See Also

- `/blockers` - Show all tasks blocking a specific task
- `/depend` - Create/remove dependency relationships
