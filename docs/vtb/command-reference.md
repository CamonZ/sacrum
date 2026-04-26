# Command Reference

## Task Lifecycle

| Command | Description |
|---------|-------------|
| `vtb add` | Create a new task |
| `vtb show <id>` | Show full task details |
| `vtb list` | List tasks with filters |
| `vtb update <id>` | Update task fields |
| `vtb delete <id>` | Delete a task |
| `vtb archive <id>` | Soft-delete (archive) |
| `vtb unarchive <id>` | Restore archived task |
| `vtb ready` | Show actionable items |

## Dependencies

| Command | Description |
|---------|-------------|
| `vtb depend <a> --on <b>` | Create dependency (a blocked by b) |
| `vtb undepend <a> --on <b>` | Remove dependency |
| `vtb blockers <id>` | Show full blocker tree |
| `vtb path <from> <to>` | Find shortest dependency path |

## Workflow Navigation

| Command | Description |
|---------|-------------|
| `vtb transition-to <id> <target>` | Move to a step (by name or UUID) |
| `vtb start-step <id>` | Mark current step as in progress |
| `vtb complete-step <id>` | Mark current step as done |
| `vtb reject-step <id> <target> [-f "..."]` | Reject step with feedback |

## Workflow Management

| Command | Description |
|---------|-------------|
| `vtb workflow add` | Create a workflow |
| `vtb workflow list` | List workflows |
| `vtb workflow show <id>` | Show workflow details |
| `vtb workflow update <id>` | Update workflow properties |
| `vtb workflow delete <id>` | Delete a workflow |
| `vtb workflow assign <task> <wf>` | Assign task to workflow |
| `vtb workflow unassign <task>` | Remove workflow assignment |
| `vtb workflow transition add` | Create cross-workflow transition |
| `vtb workflow transition list` | List transitions |
| `vtb workflow transition delete` | Delete a transition |

## Step Management

| Command | Description |
|---------|-------------|
| `vtb step add <name> -w <wf>` | Create a step |
| `vtb step list <wf>` | List steps in a workflow |
| `vtb step show <id>` | Show step details |
| `vtb step update <id>` | Update step properties |
| `vtb step delete <id>` | Delete a step |

## Content

| Command | Description |
|---------|-------------|
| `vtb section <id> <type> "..."` | Add a section |
| `vtb sections <id>` | List sections |
| `vtb unsection <id> <type>` | Remove a section |
| `vtb check-item <id> <n>` | Mark checklist item as done |
| `vtb uncheck-item <id> <n>` | Uncheck a checklist item |
| `vtb ref <id> "path"` | Add code reference |
| `vtb refs <id>` | List code references |
| `vtb unref <id> "path"` | Remove code reference |
| `vtb criterion-ref <id> <n> "path"` | Link code to test criterion |

## Execution

| Command | Description |
|---------|-------------|
| `vtb run <id>` | Execute current step via daemon |
| `vtb run-workflow <id>` | Orchestrate full workflow |
| `vtb execution create <id>` | Create execution record |
| `vtb execution list <id>` | List executions for task |
| `vtb execution show <id>` | Show execution details |
| `vtb execution update <id>` | Update execution status |
| `vtb execution log <id> "msg"` | Add log entry |

## Daemon

| Command | Description |
|---------|-------------|
| `vtb daemon install` | Install as launchd service |
| `vtb daemon uninstall` | Uninstall service |
| `vtb daemon status` | Check daemon status |

## Other

| Command | Description |
|---------|-------------|
| `vtb review <id>` | Toggle human review flag |
| `vtb init` | Initialize project |
