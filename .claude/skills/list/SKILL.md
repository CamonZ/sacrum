---
name: list
description: List and filter tasks
---

# /list

List and filter tasks. Displays tasks in a tree view by default.

## Basic listing

```bash
vtb list                          # All tasks (tree view, excludes done/archived)
vtb list --flat                   # Flat table view
vtb list --step backlog           # By workflow step name
vtb list --step in_progress       # Currently active
vtb list --level epic             # By level
vtb list --priority high          # By priority
vtb list --tag backend            # By tag
```

## Filtering by workflow

```bash
vtb list --workflow <workflow-id>   # Tasks in specific workflow
vtb list --step review              # Tasks at specific step
vtb list -w <wf-id> --step review   # Combine workflow + step
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
vtb list --include-archived       # Include archived items (excluded by default)
vtb list --search "auth"          # Search in title and description
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--level` | `-l` | Filter by level (repeatable) |
| `--step` | | Filter by current workflow step name (repeatable) |
| `--priority` | `-p` | Filter by priority (repeatable) |
| `--tag` | `-t` | Filter by tag (repeatable) |
| `--workflow` | `-w` | Filter by workflow ID |
| `--root` | | Show only root items |
| `--parent` | | Show children of task |
| `--all` | | Include done items |
| `--include-archived` | | Include archived items |
| `--search` | | Search in title/description |
| `--flat` | | Table view instead of tree |

## Note on workflow steps

Tasks don't have a standalone status — their position is defined by the workflow's current step. Filter by step name (e.g., `backlog`, `todo`, `in_progress`, `done`); valid values depend on the workflow steps configured in your project.

## Display modes
- **Tree (default)** - Hierarchical view showing parent-child relationships
- **Flat (`--flat`)** - Table view with columns: ID, Level, Status, Priority, Title, Tags
