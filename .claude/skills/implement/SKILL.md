---
name: implement
description: End-to-end ticket implementation — creates a worktree, runs the ticket-implementer agent, simplifies the code, commits, and creates a PR. Use when the user wants to implement a ticket hands-off.
argument-hint: "[ticket-id]"
---

# /implement

Implement a ticket end-to-end: worktree, agent, simplify, commit, PR.

## Arguments

- `$ARGUMENTS` — optional ticket ID (short or full UUID). If omitted, infer from current conversation context.

## Steps

Execute these steps in order. If any step fails, stop and report the error.

### 1. Resolve the ticket

If a ticket ID was provided (`$ARGUMENTS`), use it. Otherwise, determine the ticket from conversation context (e.g., the ticket we've been discussing or the next ready ticket).

Run `vtb show <ticket-id>` to confirm the ticket exists and get its full details.

### 2. Create a worktree

Create a git worktree for the ticket:

```bash
git worktree add ../sacrum-<short-id> -b <short-id>-<slugified-title>
```

Where `<short-id>` is the first 8 characters of the ticket UUID and `<slugified-title>` is the ticket title lowercased with spaces replaced by hyphens (max 60 chars).

### 3. Prepare Tidewave for the worktree

Before launching the `ticket-implementer` agent, make Tidewave available for the
new worktree. The agent session only receives MCP tools that are available when
it starts, so this setup must happen before spawning the agent.

1. Pick a free Phoenix port for the worktree app.
2. Start the Phoenix app from the worktree, for example:

```bash
PORT=<free-port> MIX_ENV=dev mix phx.server
```

3. Start or repoint the stable Tidewave proxy to that worktree app:

```bash
python3 scripts/tidewave_mcp_proxy.py http://localhost:<free-port>
```

The stable Codex MCP URL is configured as `http://localhost:4499/tidewave/mcp`.
If port `4499` is already in use, check `http://127.0.0.1:4499/health`. Reuse it
only when it already targets the current worktree app. If it targets another
worktree and the process is `tidewave_mcp_proxy.py`, stop that old proxy and
restart it for the current worktree. If another process owns the port, stop and
report the conflict.

4. Confirm the proxy is healthy:

```bash
curl -sf http://127.0.0.1:4499/health
```

5. Confirm the current Codex tool surface includes the Tidewave `project_eval`
MCP tool. If the tool is still not visible after the proxy is healthy, refresh
MCP servers or restart the Codex session before spawning the ticket agent. Do
not launch `ticket-implementer` without the tool; it will reproduce the
missing-tool failure.

After the agent starts, its first Tidewave check must verify `File.cwd!()` via
`project_eval` and confirm the result is the worktree path.

### 4. Implement the ticket

Launch the `ticket-implementer` agent to work on the ticket in the worktree directory. Pass it:

- The full ticket ID
- The worktree path
- Instructions to run `vtb show <ticket-id>` for ticket details
- Instructions to verify Tidewave with `project_eval` before implementation and to stop if the tool is unavailable or points at the wrong working directory
- Instructions to run `mix test` after implementation
- Instructions to mark checklist items done with `vtb check-item <ticket-id> <number>` as they complete each item

Wait for the agent to finish. If it fails, report the error and stop.

### 5. Simplify the code

Run `/simplify` on the changes in the worktree. This launches review agents and fixes any issues found.

### 6. Run tests

Run `mix test` in the worktree to confirm everything passes after simplification.

### 7. Commit

Stage all changed files and commit with the message format:

```
[<short-id>] <ticket-title>

<brief description of changes>
```

Follow the project's commit conventions from CLAUDE.md. Do NOT push or commit automatically — present the diff to the user and ask for approval first.

### 8. Create PR

After the user approves the commit:

- Push the branch with `-u` flag
- Create a PR using `gh pr create` with:
  - Title: `[<short-id>] <ticket-title>`
  - Body: summary of changes, test results, checklist of what was done

Return the PR URL when done.
