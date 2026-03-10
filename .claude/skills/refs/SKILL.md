---
name: refs
description: List all code references for a task
---

# /refs

List all code references for a task, sorted by file path and line number.

## Usage

```bash
vtb refs <task-id>
```

## Output

Displays a table with columns: File, Lines, Name, Description.

```
Code references for: abc123 "Implement auth"
════════════════════════════════════════════════════════════

File              Lines    Name           Description
────────────────  ───────  ─────────────  ───────────────────────
src/auth.rs       L42      verify_token   Token validation logic
src/auth.rs       L80-95   refresh_token  Token refresh handler
src/models.rs     L10      User           User model definition
```

## Related commands

```bash
vtb ref <task-id> "src/file.rs:L42"       # Add a reference
vtb unref <task-id> "src/file.rs"          # Remove by file
vtb unref <task-id> --all                  # Remove all refs
```
