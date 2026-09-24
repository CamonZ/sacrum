defmodule Sacrum.Repo.Migrations.AddConfigToWorkflowSteps do
  @moduledoc """
  Expand step: adds the step_type-discriminated `config` column, copies each
  row's type-specific columns into it, and folds the behaviorally identical
  `execute`/`evaluate` types into `llm_inference`. `human_input`, `stop`, and
  `finish` rows get a null config; `human_input` has no defined semantics yet,
  so its prompt and output_schema are not carried over, and route steps no
  longer use their prompt or output schema.

  Each config also records its variant as `__type__`, which the
  polymorphic embed needs to load it.

  The legacy columns stay in place until the contract migration drops them.
  Rolling back maps `llm_inference` to `execute`, so the execute/evaluate
  distinction is not recoverable.
  """

  use Ecto.Migration

  @inference_fields """
  'prompt', prompt,
  'output_schema', output_schema,
  'agents', to_jsonb(agents),
  'skills', to_jsonb(skills),
  'agent_config', agent_config
  """

  def up do
    alter table(:workflow_steps) do
      add :config, :map, null: true
    end

    execute """
    UPDATE workflow_steps
    SET step_type = 'llm_inference',
        config = jsonb_build_object('__type__', 'llm_inference', 'version', 1, #{@inference_fields})
    WHERE step_type IN ('execute', 'evaluate')
    """

    execute """
    UPDATE workflow_steps
    SET config = jsonb_build_object('__type__', 'route', 'version', 1, 'route_config', route_config)
    WHERE step_type = 'route'
    """

    execute """
    UPDATE workflow_steps
    SET config = jsonb_build_object('__type__', 'wait_children', 'version', 1, 'output_schema', output_schema)
    WHERE step_type = 'wait_children'
    """

    execute "ALTER TABLE workflow_steps ALTER COLUMN step_type SET DEFAULT 'llm_inference'"
    execute "ALTER TABLE step_executions ALTER COLUMN step_type SET DEFAULT 'llm_inference'"
  end

  def down do
    execute "ALTER TABLE step_executions ALTER COLUMN step_type SET DEFAULT 'execute'"
    execute "ALTER TABLE workflow_steps ALTER COLUMN step_type SET DEFAULT 'execute'"

    execute """
    UPDATE workflow_steps SET step_type = 'execute' WHERE step_type = 'llm_inference'
    """

    alter table(:workflow_steps) do
      remove :config
    end
  end
end
