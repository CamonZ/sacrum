# LLM MCP Config

An `llm_inference` step can supply the MCP configuration the daemon gives the
agent, and can ask the daemon to ignore ambient MCP configuration. Both
settings are existing-style keys in `config.agent_config`, which Sacrum
already forwards to the daemon verbatim in `run_step`:

```json
{
  "provider": "anthropic",
  "model": "claude-opus-5-5",
  "mcp_config": [
    {
      "mcpServers": {
        "gate": {
          "command": "gate-mcp",
          "args": ["--stdio"],
          "env": { "GATE_TOKEN": "${GATE_TOKEN}" }
        }
      }
    },
    "/etc/vertebrae/mcp/docs.json"
  ],
  "strict_mcp_config": true,
  "allowed_tools": ["mcp__gate__lookup"]
}
```

This is the Sacrum side of a contract shared with the Vertebrae daemon
(Vertebrae ticket `3e77b317`, "Enforce daemon tool/MCP isolation"). Sacrum
validates the shape and delivers it. The daemon applies it.

## Keys

| Key | Meaning |
|-----|---------|
| `mcp_config` | List of MCP configs to load. Each entry is inline MCP JSON (an object) or a daemon-local path (a string) |
| `strict_mcp_config` | `true` loads only `mcp_config` and ignores project, user and plugin MCP configuration (Claude `--strict-mcp-config`). Omitted or `false` keeps ambient loading |
| `allowed_tools` / `disallowed_tools` | Existing keys. They also restrict MCP tools, named `mcp__<server>__<tool>` |
| `tools` | Existing key for the built-in tool selection |

`strict_mcp_config: true` with no `mcp_config` (or `[]`) means no MCP servers
at all.

### Inline entries

An inline entry is an MCP JSON object containing only `mcpServers`, with at
least one server. Server names may only contain letters, digits, `_` and `-`.
Each server declares exactly one of `command` (stdio) or `url` (HTTP/SSE).
Other server fields such as `args` and `type` go to the daemon unchanged.
Inline MCP JSON must be an object; a JSON-encoded string is rejected.

### Daemon-path entries

A string entry is a file on the executing daemon's machine. It must start with
`/` or `~/` and must not contain `..` segments. Workspace-relative paths are
rejected, so the project's `.mcp.json` is never implied. Sacrum cannot read
the file, so the daemon validates its contents.

## Responsibilities

| Concern | Owner |
|---------|-------|
| Shape validation on create/update and again before dispatch | Sacrum |
| Recording the config in `StepExecution.config` and sending it in `run_step` | Sacrum |
| Reading daemon-path files, materializing inline JSON in per-execution temporary files, and cleaning them up | Daemon |
| Strict isolation, and enforcing `allowed_tools`/`disallowed_tools` | Daemon |
| Translating for each provider (Claude flags, Codex app-server config), or rejecting what a harness cannot guarantee | Daemon |
| Applying daemon-side policy, which a step request cannot broaden | Daemon |
| Resolving `${VAR}` credential references and redacting them in logs | Daemon |

A valid config in Sacrum is a request, not a guarantee.

## Validation

`Sacrum.Repo.Schemas.WorkflowStep.Config.McpConfig` checks the config at two
points:

1. **Create/update** (`createWorkflowStep`, `updateWorkflowStep`, bundle
   import). The failure is a config field error, for example
   `config.agent_config: $.agent_config.mcp_config[0]: must be an absolute daemon-local path (starting with / or ~/)`.
   The GraphQL error carries `code: "mcp_config_invalid"`; bundle-import
   errors carry the same code, with the path given in manifest form.
2. **Dispatch**, while `ExecutionConfig` renders the step. Rows stored before
   this validation existed are checked again. A failing config fails the
   dispatch with `{:config_render_failed, %{code: :mcp_config_invalid, ...}}`.
   This happens before a `StepExecution` exists or a `run_step` is sent, and
   the TaskRun fails with `dispatch_failed`.

`{{ }}` interpolations are rejected, because `agent_config` is not templated
and a template would otherwise reach the daemon as literal text. Other
`agent_config` keys are not validated here.

## Compatibility

Older Vertebrae daemons declare `mcp_config` as a list of strings.

- **Inline object entries** fail deserialization on those daemons, so the run
  fails rather than running without the config.
- **`strict_mcp_config`** is an unknown field to those daemons and is ignored.

## Credentials and redaction

Workflow config is ordinary, readable data. It is returned by GraphQL, copied
into every execution record, and exported in bundles. Do not store
credentials in it.

- In inline entries, every `env` and `headers` value must reference a
  variable in the daemon's environment as `${NAME}`. For example,
  `"GATE_TOKEN": "${GATE_TOKEN}"` or `"Authorization": "Bearer ${DOCS_TOKEN}"`.
  Literal values are rejected, and so are `${NAME:-default}` defaults, because
  a default could hold a secret. The daemon resolves the reference at run time
  and must redact the resolved value.
- Sacrum cannot detect secrets in `args`, `url` or other fields. Do not put
  credentials there either.
- For credentials in a file, use a daemon-path entry. The file stays on the
  daemon's machine, and Sacrum only stores its path.
- Validation errors and dispatch-failure logs name the path of the bad field
  but never its value.
