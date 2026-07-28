defmodule Sacrum.Repo.Migrations.SimplifyArtifactStorageSchema do
  use Ecto.Migration

  def up do
    drop index(:artifacts, [:project_id, :visibility, :redaction_state, :inserted_at])
    drop constraint(:artifacts, :artifacts_artifact_state_check)
    drop constraint(:artifacts, :artifacts_visibility_check)
    drop constraint(:artifacts, :artifacts_redaction_state_check)

    alter table(:artifacts) do
      add :filename, :text, null: false
      add :body, :text, null: false
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
    drop constraint(:artifact_links, :artifact_links_subject_type_check)

    create constraint(:artifact_links, :artifact_links_subject_type_check,
             check:
               "subject_type IN ('task', 'task_section', 'workflow', 'task_run', 'step_execution')"
           )

    alter table(:artifacts) do
      add :artifact_type, :string, null: false
      add :artifact_state, :string, null: false
      add :visibility, :string, null: false
      add :redaction_state, :string, null: false
      add :title, :string
      add :content, :text
      add :data, :map, null: false, default: %{}
      add :storage_ref, :string
      remove :filename
      remove :body
    end

    create index(:artifacts, [:project_id, :visibility, :redaction_state, :inserted_at])

    create constraint(:artifacts, :artifacts_artifact_state_check,
             check:
               "artifact_state IN ('draft', 'pending_approval', 'approved', 'applied', 'rejected')"
           )

    create constraint(:artifacts, :artifacts_visibility_check,
             check: "visibility IN ('public', 'internal')"
           )

    create constraint(:artifacts, :artifacts_redaction_state_check,
             check: "redaction_state IN ('not_needed', 'redacted', 'blocked')"
           )
  end
end
