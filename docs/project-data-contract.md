# Project Data Contract

Sacrum's supported project-data boundary is a versioned JSON document. It is a
transport format for persisted project records, not a legacy database dump or a
database-migration command.

`Sacrum.Export.project_data/1` accepts a map containing `:workflow_steps` and
`:step_executions`. It returns this shape:

```json
{
  "version": 1,
  "workflow_steps": [],
  "step_executions": []
}
```

`Sacrum.Export.encode/1` serializes the document. `Sacrum.Import.load/1`
accepts either that JSON string or its decoded map and returns atom-keyed
changeset attributes.

Workflow-step records preserve `route_config` as inert JSON. A present program
is authoritative even when `prompt` is also present; import never derives rules
from the prompt. A prompt-only route keeps its prompt and omits `route_config`.
An imported route with neither value is rejected as non-runnable.

StepExecution records preserve the audit boundary exactly:

- `context.route` contains the `RouteAudit` document, including its source
  execution, configuration version, matched rule, default flag, and context
  snapshot.
- `transition_result` remains the JSON string containing the canonical target.
- `handoff` remains the carried payload.
- `output` is ordinary step output and is never used to reconstruct audit data.

To persist imported records, callers pass
`Sacrum.Import.workflow_step_attrs/1` or
`Sacrum.Import.step_execution_attrs/1` through the normal account/repository
write path. `workflow_step_changeset/2` and `step_execution_changeset/2`
provide the corresponding changesets. Therefore an invalid present
`route_config` returns the same path-aware `WorkflowStep` validation error as a
normal write. The import boundary does not perform legacy row conversion,
backfill, or live database mutation.
