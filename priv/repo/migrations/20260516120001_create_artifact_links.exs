defmodule Sacrum.Repo.Migrations.CreateArtifactLinks do
  use Ecto.Migration

  def change do
    create table(:artifact_links, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :artifact_id, references(:artifacts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject_type, :string, null: false
      add :subject_id, :binary_id, null: false
      add :relationship_kind, :string, null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      add :metadata, :map

      timestamps(type: :utc_datetime_usec)
    end

    create index(:artifact_links, [:artifact_id])
    create index(:artifact_links, [:subject_type, :subject_id])
    create index(:artifact_links, [:project_id])

    create constraint(:artifact_links, :artifact_links_subject_type_check,
             check:
               "subject_type IN ('task', 'task_section', 'chat_session', 'task_run', 'step_execution')"
           )

    create constraint(:artifact_links, :artifact_links_relationship_kind_check,
             check:
               "relationship_kind IN ('produced_by', 'attached_to', 'evidence_for', 'source_for', 'validates', 'supersedes')"
           )
  end
end
