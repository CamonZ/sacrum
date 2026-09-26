defmodule Sacrum.Repo.Migrations.ReplaceStepExecutionPromptWithConfig do
  @moduledoc """
  Replaces `step_executions.prompt` with `step_executions.config`: the step's
  config as the execution used it, with templates rendered (the llm_inference
  prompt, the structured_inference state), in the same step_type-discriminated
  shape as `workflow_steps.config`.

  Existing executions only recorded their rendered prompt, so the backfill is
  best-effort: the other config fields come from the step's current config,
  and the rendered prompt replaces its template. llm_inference executions whose
  step no longer exists keep only their prompt. Rolling back restores `prompt`
  from `config`.
  """

  use Ecto.Migration

  def up do
    alter table(:step_executions) do
      add :config, :map
    end

    execute """
    UPDATE step_executions AS e
    SET config = CASE
      WHEN e.step_type = 'llm_inference'
        THEN jsonb_set(ws.config, '{prompt}', COALESCE(to_jsonb(e.prompt), 'null'::jsonb))
      ELSE ws.config
    END
    FROM workflow_steps AS ws
    WHERE ws.id = e.step_id AND ws.config IS NOT NULL
    """

    execute """
    UPDATE step_executions
    SET config = jsonb_build_object(
      '__type__', 'llm_inference', 'version', 1, 'prompt', prompt,
      'output_schema', NULL, 'agents', '[]'::jsonb, 'skills', '[]'::jsonb,
      'agent_config', '{}'::jsonb
    )
    WHERE step_type = 'llm_inference' AND config IS NULL
    """

    alter table(:step_executions) do
      remove :prompt
    end
  end

  def down do
    alter table(:step_executions) do
      add :prompt, :text
    end

    execute "UPDATE step_executions SET prompt = config->>'prompt' WHERE config IS NOT NULL"

    alter table(:step_executions) do
      remove :config
    end
  end
end
