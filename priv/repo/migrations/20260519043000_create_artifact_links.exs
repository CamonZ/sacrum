defmodule Sacrum.Repo.Migrations.CreateArtifactLinks do
  use Ecto.Migration

  def change do
    create table(:artifact_links, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :artifact_id, references(:artifacts, type: :binary_id, on_delete: :delete_all),
        null: false

      add :project_id, references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :subject_type, :string, null: false
      add :subject_id, :binary_id, null: false
      add :relationship_kind, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:artifact_links, [:user_id, :project_id, :subject_type, :subject_id])
    create index(:artifact_links, [:user_id, :project_id, :artifact_id])
    create index(:artifact_links, [:project_id, :relationship_kind, :inserted_at])

    create constraint(:artifact_links, :artifact_links_subject_type_check,
             check: "subject_type IN ('task', 'task_section', 'chat_session')"
           )

    create constraint(:artifact_links, :artifact_links_relationship_kind_check,
             check:
               "relationship_kind IN ('attached_to', 'evidence_for', 'produced_by', 'source_for', 'result_of', 'supersedes')"
           )
  end
end
