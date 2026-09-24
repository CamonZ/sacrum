defmodule Sacrum.Repo.Migrations.DropLegacyWorkflowStepConfigColumns do
  @moduledoc """
  Contract step: every reader now uses `workflow_steps.config`, so the
  type-specific columns it replaced are dropped. Rolling back re-adds them and
  restores their values from `config`.
  """

  use Ecto.Migration

  def up do
    alter table(:workflow_steps) do
      remove :prompt
      remove :output_schema
      remove :agents
      remove :skills
      remove :agent_config
      remove :route_config
    end
  end

  def down do
    alter table(:workflow_steps) do
      add :prompt, :text
      add :output_schema, :map
      add :agents, {:array, :string}, default: []
      add :skills, {:array, :string}, default: []
      add :agent_config, :map, default: %{}
      add :route_config, :map
    end

    execute """
    UPDATE workflow_steps
    SET prompt = config->>'prompt',
        output_schema = NULLIF(config->'output_schema', 'null'::jsonb),
        route_config = NULLIF(config->'route_config', 'null'::jsonb),
        agent_config = CASE WHEN config ? 'agent_config'
                            THEN NULLIF(config->'agent_config', 'null'::jsonb)
                            ELSE agent_config END,
        agents = CASE WHEN config ? 'agents' THEN #{text_array("agents")} ELSE agents END,
        skills = CASE WHEN config ? 'skills' THEN #{text_array("skills")} ELSE skills END
    WHERE config IS NOT NULL
    """
  end

  defp text_array(key) do
    """
    (CASE WHEN jsonb_typeof(config->'#{key}') = 'array'
          THEN ARRAY(SELECT jsonb_array_elements_text(config->'#{key}'))::varchar[]
     END)
    """
  end
end
