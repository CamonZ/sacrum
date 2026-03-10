---
name: ref
description: Link tasks to code locations
---

# /ref

Link tasks to code locations.

## Add references

```bash
# File only
vtb ref <task-id> "src/auth.rs"

# Specific line
vtb ref <task-id> "src/auth.rs:L42"

# Line range
vtb ref <task-id> "src/auth.rs:L42-60"

# With name/description
vtb ref <task-id> "src/auth.rs:L42" --name "verify_token" --desc "Token validation logic"
```

## View/remove references

```bash
vtb refs <task-id>                    # List all
vtb unref <task-id> --all             # Remove all
vtb unref <task-id> "src/auth.rs"     # Remove by exact file path
```

## Why refs matter
- Links tasks to actual code locations
- Provides context when starting work
- Tracks which files a task affects
