---
name: List Tasks
description: List and filter tasks
user-invocable: true
allowed-tools: ["Bash"]
---

# /list

List and filter tasks. Displays tasks in a tree view by default.

## Basic listing

```bash
vtb list                          # All tasks (tree view)
vtb list --flat                   # Flat table view
vtb list --status todo            # By status
vtb list --status in_progress     # Currently active
vtb list --level epic             # By level
vtb list --priority high          # By priority
vtb list --tag backend            # By tag
```

## Filtering by workflow

```bash
vtb list --workflow implementation  # Tasks in specific workflow
vtb list --step review              # Tasks at specific step
vtb list -w impl --step coding      # Combine workflow and step
```

## Filtering by parent

```bash
vtb list --parent <ID>            # Show children of a specific task
vtb list --parent abc123 --all    # Include done children
vtb list --root                   # Show only root items (no parent)
```

## Additional options

```bash
vtb list --all                    # Include done items (excluded by default)
vtb list --search "auth"          # Search in title and description
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--level` | `-l` | Filter by level (repeatable) |
| `--status` | `-s` | Filter by status (repeatable) |
| `--priority` | `-p` | Filter by priority (repeatable) |
| `--tag` | `-t` | Filter by tag (repeatable) |
| `--workflow` | `-w` | Filter by workflow ID |
| `--step` | | Filter by current step name |
| `--root` | | Show only root items |
| `--parent` | | Show children of task |
| `--all` | | Include done items |
| `--search` | | Search in title/description |
| `--flat` | | Table view instead of tree |

## Statuses
- `backlog` - Not yet triaged
- `todo` - Ready to work on
- `in_progress` - Currently working
- `pending_review` - Submitted for review
- `done` - Completed
- `rejected` - Rejected (with reason)

## Display modes
- **Tree (default)** - Hierarchical view showing parent-child relationships
- **Flat (`--flat`)** - Table view with columns: ID, Level, Status, Priority, Title, Tags
