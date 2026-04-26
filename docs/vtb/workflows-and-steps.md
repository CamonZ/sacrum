# Workflows and Steps

Tasks don't have a standalone status. A task's position is defined by its **workflow** and **step** within that workflow.

## Creating Workflows

```bash
# Basic with inline steps
vtb workflow add "Implementation" --step Coding:sonnet --step Testing:haiku --step Docs:haiku

# With description and options
vtb workflow add "Code Review" -d "Review and approval" \
  --step Review:sonnet --step Approved:haiku \
  --auto-advance --kanban-column "In Review"

# Mark as default for new tasks
vtb workflow add "Standard" --step Backlog:sonnet --step Done:haiku --default
```

## Managing Workflows

```bash
vtb workflow list
vtb workflow show <id>
vtb workflow update <id> --name "Dev"
vtb workflow update <id> --auto-advance       # or --no-auto-advance
vtb workflow update <id> --kanban-column "Active"
vtb workflow update <id> --default
vtb workflow delete <id>                      # No assigned tasks allowed
vtb workflow assign <task-id> <workflow-id>   # Starts at first step
vtb workflow unassign <task-id>
```

## Managing Steps

```bash
# Add steps to a workflow
vtb step add "Testing" -w <wf-id> --goal "Verify implementation" --model sonnet --order 1
vtb step add "Approved" -w <wf-id> --final
vtb step add "Needs Work" -w <wf-id> --transition-to <step-id>

# With prompt and agent config (prompt is a Liquid template — see "Prompt Templates" below)
vtb step add "Coding" -w <wf-id> \
  --prompt "Implement {{ task.id }}: {{ task.title }}" \
  --agent-config '{"model":"opus","max_budget_usd":5.0}'

# With agents and skills
vtb step add "Review" -w <wf-id> --agent .claude/agents/reviewer.md --skill review

# Step types: execute (default), evaluate, route
vtb step add "Evaluate" -w <wf-id> --step-type evaluate \
  --output-schema '{"type":"object","required":["passed"],"properties":{"passed":{"type":"boolean"}}}'

# List, show, update, delete
vtb step list <wf-id>
vtb step show <id>
vtb step update <id> --name "New Name"
vtb step delete <id>
```

## Step Properties

| Property | Description |
|----------|-------------|
| `name` | Step name (e.g., "backlog", "coding", "review") |
| `order` | Execution order (lower = first, 0-indexed) |
| `final` | Marks workflow as complete when reached |
| `goal` | What this step accomplishes |
| `prompt` | Liquid template for the executing agent (see "Prompt Templates" below) |
| `model` | AI model shortcut (sonnet, haiku, opus) |
| `agent-config` | Full LLM config JSON |
| `agents` | Agent file paths |
| `skills` | Slash commands available during this step |
| `transition-to` | Restrict which steps can follow |
| `step-type` | `execute`, `evaluate`, or `route` |
| `output-schema` | JSON Schema for structured output |

## Step Types

| Type | Description |
|------|-------------|
| `execute` | Default. Runs the step's prompt and produces output. |
| `evaluate` | Assesses output of a previous step. Emits structured JSON matching `output_schema`. |
| `route` | Terminal-of-workflow decision step. Emits `{ transition_to, transition_type, handoff }` to direct to the next workflow/step. |

## Prompt Templates

Step prompts are **Liquid templates** rendered by the daemon before invoking the agent. Use `{{ ... }}` for variable interpolation and `{% ... %}` for control flow.

### Available Context

#### `task.*` — task-level data

| Field | Type | Description |
|-------|------|-------------|
| `task.id` | string | Task UUID |
| `task.title` | string | Task title |
| `task.description` | string | Free-form description |
| `task.level` | string | `epic`, `ticket`, or `task` |
| `task.tags` | list | Tag strings |
| `task.code_refs` | list | Each: `{ path, line_start, line_end, name, description }` |

Section content is exposed as **lists** keyed by the section type (plural):

| Field | Source section type |
|-------|---------------------|
| `task.goals` | `goal` |
| `task.context` | `context` |
| `task.current_behavior` | `current_behavior` |
| `task.desired_behavior` | `desired_behavior` |
| `task.testing_criteria` | `testing_criterion` |
| `task.constraints` | `constraint` |
| `task.anti_patterns` | `anti_pattern` |
| `task.checklist_items` | `checklist_item` |
| `task.assumptions` | `assumptions` |
| `task.failure_tests` | `failure_test` |

Each list contains the raw section content strings in ordinal order. **Lists are nil/empty when no sections of that type exist** — always guard before printing (see "Nil safety" below).

#### `execution.*` — current execution context

| Field | Description |
|-------|-------------|
| `execution.previous_output` | Output of the immediately preceding step (string for execute, parsed object/list for evaluate/route). Nil on the first step. |
| `execution.handoff` | Map carried over from the previous workflow's route step (e.g. `{ feedback, pr_url, branch, needs_human, note, source_workflow }`). Nil if there is no inbound handoff. |
| `execution.retry_count` | Times this step has retried in the current execution. |
| `execution.run_count` | Total times this step has run for this task across all workflow iterations (ok + ko). |
| `execution.completed_count` | Times this step has completed successfully for this task. |
| `execution.failed_count` | Times this step has failed for this task. |
| `execution.duration_ms` | Elapsed time of the current execution. |
| `execution.history` | List of prior steps in this workflow run: `{ step_name, status, output, duration_ms }`. |

#### `workflow.*` — current workflow + step metadata

| Field | Description |
|-------|-------------|
| `workflow.name` | Workflow name |
| `workflow.current_step` | Current step name |
| `workflow.current_step_goal` | Current step's `goal` field |
| `workflow.step_count` | Total steps in the workflow |
| `workflow.output_schema` | The current step's `output_schema` JSON, if defined. Nil otherwise. |

### Nil safety

Liquid does not error on nil access, but it will render the literal string `""` (or section labels with no content). **Always guard before printing**:

```liquid
{# Lists — guard with size check #}
{% if task.testing_criteria and task.testing_criteria.size > 0 %}Testing criteria:
{% for t in task.testing_criteria %}- {{ t }}
{% endfor %}{% endif %}

{# Scalars — simple presence check #}
{% if task.description %}Description: {{ task.description }}
{% endif %}

{# Nested — chain `and` to short-circuit before access #}
{% if execution.handoff and execution.handoff.feedback %}
Prior feedback: {{ execution.handoff.feedback }}
{% endif %}

{# Optional schema — only print when present #}
{% if workflow.output_schema %}Output JSON matching:
{{ workflow.output_schema }}{% endif %}
```

Without the guards, the prompt will render bare section headers with empty bodies — confusing the agent and wasting tokens.

### Reading prior step output

Inside a workflow, each step sees the previous step's output via `execution.previous_output`. For `evaluate` and `route` steps that consume structured output, treat it as a string and let the model parse it:

```liquid
{% if execution.previous_output %}Input:
{{ execution.previous_output }}
{% endif %}
```

For deeper history (e.g. a `route` step that needs the `pr` step's output two hops back), iterate `execution.history`:

```liquid
{% for h in execution.history %}{% if h.step_name == "pr" %}PR: {{ h.output }}{% endif %}{% endfor %}
```

### Reading inbound handoff (cross-workflow)

When a previous workflow's route step transitioned here with a handoff payload, it is available as `execution.handoff`:

```liquid
{% if execution.handoff and execution.handoff.pr_url %}
Reviewing PR {{ execution.handoff.pr_url }} on branch {{ execution.handoff.branch }}.
{% endif %}

{% if execution.handoff and execution.handoff.feedback %}
A previous attempt was rejected. Address this first:
{{ execution.handoff.feedback }}
{% endif %}
```

### Telling evaluate/route steps to emit schema-conforming JSON

Evaluate and route steps must emit JSON matching their `output_schema`. Include this directive in the prompt so the model knows what shape to produce:

```liquid
{% if workflow.output_schema %}Output JSON matching:
{{ workflow.output_schema }}{% endif %}
```

Without this, the model will return prose — and downstream steps will get `execution.previous_output` as unparseable text.
