defmodule Sacrum.Repo.Migrations.BackfillWorkflowStepHarness do
  use Ecto.Migration

  def up do
    execute """
    UPDATE workflow_steps
    SET harness = CASE COALESCE(config->>'provider', config->'agent_config'->>'provider')
      WHEN 'openai' THEN 'codex'
      WHEN 'codex' THEN 'codex'
      WHEN 'anthropic' THEN 'claude'
      WHEN 'claude' THEN 'claude'
      WHEN 'typesafe' THEN 'typesafe'
    END
    WHERE COALESCE(config->>'provider', config->'agent_config'->>'provider')
      IN ('openai', 'codex', 'anthropic', 'claude', 'typesafe')
    """
  end

  def down do
    execute """
    UPDATE workflow_steps
    SET harness = NULL
    WHERE harness = CASE COALESCE(config->>'provider', config->'agent_config'->>'provider')
      WHEN 'openai' THEN 'codex'
      WHEN 'codex' THEN 'codex'
      WHEN 'anthropic' THEN 'claude'
      WHEN 'claude' THEN 'claude'
      WHEN 'typesafe' THEN 'typesafe'
    END
    """
  end
end
