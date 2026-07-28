defmodule Sacrum.Repo.Migrations.SimplifyArtifactStorageSchema do
  use Ecto.Migration

  def up do
    alter table(:artifacts) do
      add :filename, :string
      add :body, :text
    end

    flush()

    execute("""
    UPDATE artifacts
    SET
      filename =
        CASE
          WHEN title ~* '\\.(md|json)$' THEN title
          ELSE LEFT(COALESCE(NULLIF(title, ''), NULLIF(artifact_type, ''), 'artifact-' || id::text), 250) ||
            CASE
              WHEN content IS NULL AND data <> '{}'::jsonb THEN '.json'
              ELSE '.md'
            END
        END,
      body =
        CASE
          WHEN NULLIF(content, '') IS NOT NULL THEN content
          WHEN data <> '{}'::jsonb THEN data::text
          WHEN NULLIF(storage_ref, '') IS NOT NULL THEN storage_ref
          WHEN NULLIF(title, '') IS NOT NULL THEN title
          ELSE 'artifact-' || id::text
        END
    """)

    drop index(:artifacts, [:project_id, :visibility, :redaction_state, :inserted_at])
    drop constraint(:artifacts, :artifacts_artifact_state_check)
    drop constraint(:artifacts, :artifacts_visibility_check)
    drop constraint(:artifacts, :artifacts_redaction_state_check)

    alter table(:artifacts) do
      modify :filename, :string, null: false
      modify :body, :text, null: false
      remove :artifact_type
      remove :artifact_state
      remove :visibility
      remove :redaction_state
      remove :title
      remove :content
      remove :data
      remove :storage_ref
    end

    drop constraint(:artifact_links, :artifact_links_subject_type_check)

    create constraint(:artifact_links, :artifact_links_subject_type_check,
             check:
               "subject_type IN ('project', 'task', 'task_section', 'workflow', 'task_run', 'step_execution')"
           )
  end

  def down do
    raise "cannot safely restore removed artifact lifecycle, visibility, redaction, or structured data"
  end
end
