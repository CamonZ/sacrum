# Execution and Daemon

## Daemon

The daemon (`vtb-daemon`) executes workflow steps via Claude Code subprocesses as a macOS launchd service.

```bash
vtb daemon install                                     # Install as launchd service
vtb daemon install --binary /usr/local/bin/vtb-daemon   # With explicit path
vtb daemon status
vtb daemon uninstall
```

## Running Steps

```bash
vtb run <task-id>            # Execute current step via daemon
vtb start-taskrun <task-id>  # Start a durable workflow run
vtb stop-taskrun <task-id>   # Stop the active durable workflow run
```

`vtb run` executes a single current step. `vtb start-taskrun` orchestrates a
durable TaskRun through all workflow steps, handling transitions, eval prompts,
and workflow chaining. `vtb stop-taskrun` stops the task's active TaskRun.

`stop` steps are orchestration boundaries, not daemon work. `vtb run` cannot
dispatch one directly. When `vtb start-taskrun` reaches a stop step, the current
TaskRun ends with `status: stopped` and `outcome_kind: run_boundary`; running
`vtb start-taskrun` again creates a new TaskRun, advances through the stop
step's single outgoing transition, and dispatches the next executable step.

## Execution Tracking

```bash
vtb execution create <task-id>
vtb execution log <execution-id> "Processing..." --level info
vtb execution update <execution-id> --status completed
vtb execution list <task-id>
vtb execution show <execution-id>
```

Use TaskRun history to distinguish an operator stop from a workflow boundary:
inspect `status`, `outcome_kind`, and `outcome_context` rather than inferring
run state from the latest step execution.
