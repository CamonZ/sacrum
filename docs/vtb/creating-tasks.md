# Creating Tasks

## Task Hierarchy

```
epic → ticket → task
```

| Level | Use for | Example |
|-------|---------|---------|
| `epic` | Large initiative, multiple features | "Sprint 0.2: News Classification" |
| `ticket` | Single deliverable | "Implement rule-based classifier" |
| `task` | Unit of work (default) | "Add earnings detection regex" |

Priorities: `low` | `medium` | `high` | `critical`

Every command supports `--json` for machine-readable output.

## Commands

```bash
# Basic
vtb add "Task title"
vtb add "Feature title" -l ticket -d "Detailed description"
vtb add "Sprint 0.3: VWAP Signals" -l epic -d "VWAP-based entry signals"

# With parent
vtb add "Create RequestData struct" --parent <ticket-id>

# With priority, tags, dependency
vtb add "Fix indicator lag" -p critical -t bug -t market-processor
vtb add "Write integration tests" --depends-on <blocker-id>

# Assign to workflow on creation
vtb add "New feature" --workflow <workflow-id>

# Mark as needing human review
vtb add "Sensitive IB config change" --needs-review
```

## Planning a Feature

```bash
# 1. Create epic
vtb add "Implement market data streaming" -l epic -d "Real-time market data support"

# 2. Break into tickets
vtb add "Add NATS consumer actors" -l ticket --parent <epic-id>
vtb add "Add indicator persistence" -l ticket --parent <epic-id>

# 3. Break tickets into tasks
vtb add "Create RSI actor" --parent <ticket-id>
vtb add "Create VWAP actor" --parent <ticket-id>

# 4. Set dependencies
vtb depend <vwap-task> --on <rsi-task>

# 5. View the plan
vtb show <epic-id>
vtb blockers <final-task-id>
```
