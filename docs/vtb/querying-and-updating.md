# Querying, Updating, and Deleting Tasks

## Listing

```bash
vtb list                           # Tree view (excludes done/archived)
vtb list --flat                    # Flat table view
vtb list --workflow <wf-id>        # By workflow
vtb list --step <step-name>        # By current step
vtb list -w <wf-id> --step <step>  # Combine filters
vtb list --level ticket            # By level
vtb list --priority high           # By priority (repeatable)
vtb list --tag backend             # By tag (repeatable)
vtb list --parent <id>             # Children of parent
vtb list --root                    # Only root items
vtb list --search "auth"           # Search title/description
vtb list --all                     # Include done items
vtb list --include-archived        # Include archived items
```

## Finding Actionable Work

```bash
vtb ready    # Highest-level items ready for work or triage
```

## Viewing Details

```bash
vtb show <id>    # Full task details with sections, refs, checklist status
```

## Updating Tasks

```bash
vtb update <id> --title "New title"
vtb update <id> --description "New description"
vtb update <id> -d ""                            # Clear description
vtb update <id> --priority high
vtb update <id> --add-tag urgent --add-tag backend
vtb update <id> --remove-tag old-tag
vtb update <id> --parent <parent-id>
vtb update <id> --parent ""                      # Remove parent
vtb update <id> --worktree /path/to/worktree
vtb update <id> --worktree ""                    # Clear worktree
vtb update <id> --edit-section checklist_item 0 "New content"
vtb update <id> --remove-section checklist_item 0
```

**Never use `vtb update` for workflow/step changes** — use `vtb transition-to`.

## Deleting and Archiving

```bash
vtb delete <id>                # Delete single task
vtb delete <id> --cascade      # Delete task and all children
vtb archive <id>               # Soft-delete
vtb unarchive <id>             # Restore
```

Archived tasks are excluded from `vtb list` by default. Use `--include-archived` to see them.

## Human Review

Human review is represented by workflow position. A task is awaiting human
action when its `current_step_id` points at a workflow step whose `step_type` is
`human_input`; task-level review metadata fields are not part of the public task
contract.
