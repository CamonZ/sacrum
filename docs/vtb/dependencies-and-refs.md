# Dependencies and Code References

## Dependencies

```bash
# Create (A depends on B — B must finish first)
vtb depend <task-a> --on <task-b>

# Remove
vtb undepend <task-a> --on <task-b>

# View
vtb blockers <id>                  # Full blocker tree
vtb blockers <id> --depth 2       # Limit depth
vtb blockers <id> --all           # Include completed blockers
vtb path <from> <to>              # Shortest path between tasks
```

## Code References

```bash
vtb ref <id> "src/actors/vwap.rs"
vtb ref <id> "src/actors/vwap.rs:L42"
vtb ref <id> "src/actors/vwap.rs:L42-60" --name "calculate" --desc "VWAP calculation"
vtb criterion-ref <id> 1 "tests/vwap_test.rs:L10-25" --name "test_vwap"
vtb refs <id>                      # List references
vtb unref <id> "src/actors/vwap.rs"
vtb unref <id> --all
```
