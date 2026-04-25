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
vtb run-workflow <task-id>   # Orchestrate full workflow automatically
```

`vtb run` executes a single step. `vtb run-workflow` orchestrates through all steps, handling transitions, eval prompts, and workflow chaining.

## Execution Tracking

```bash
vtb execution create <task-id>
vtb execution log <execution-id> "Processing..." --level info
vtb execution update <execution-id> --status completed
vtb execution list <task-id>
vtb execution show <execution-id>
```
