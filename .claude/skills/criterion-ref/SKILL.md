---
name: criterion-ref
description: Add a code reference to a testing criterion
---

# /criterion-ref

Add a code reference to a specific testing criterion. Links test implementations to their corresponding testing criteria.

## Usage

```bash
# Add reference to testing criterion by index (1-based)
vtb criterion-ref <task-id> <criterion-index> <file-spec>

# With optional name and description
vtb criterion-ref <task-id> 1 "tests/auth_test.rs:L42-60" \
  --name "test_login_success" \
  --desc "Tests successful login flow"
```

## Arguments

| Argument | Description |
|----------|-------------|
| `task-id` | Task ID containing the testing criterion |
| `criterion-index` | 1-based index of the testing criterion |
| `file-spec` | File path with optional line specification |

## Options

| Flag | Description |
|------|-------------|
| `--name` | Optional label (e.g., test function name) |
| `--description` / `--desc` | Optional description |

## File Specification Formats

```bash
# File only
vtb criterion-ref abc123 1 "tests/auth_test.rs"

# Single line
vtb criterion-ref abc123 1 "tests/auth_test.rs:L42"

# Line range
vtb criterion-ref abc123 1 "tests/auth_test.rs:L42-60"
```

## Example Workflow

1. Add testing criteria to a task:
   ```bash
   vtb section abc123 testing_criterion "User can log in with valid credentials"
   vtb section abc123 testing_criterion "Invalid password shows error message"
   ```

2. Implement tests and link them:
   ```bash
   vtb criterion-ref abc123 1 "tests/auth_test.rs:L10-25" --name "test_valid_login"
   vtb criterion-ref abc123 2 "tests/auth_test.rs:L27-45" --name "test_invalid_password"
   ```

3. View in task details:
   ```bash
   vtb show abc123
   ```

## When to Use

- Linking test implementations to testing criteria
- Tracking which tests cover which requirements
- Verifying test coverage during review

## See Also

- `/ref` - Add general code references to tasks
- `/section` - Add testing criteria to tasks
