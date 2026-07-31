defmodule Sacrum.Repo.Migrations.RemoveRelationshipKindFromArtifactLinks do
  use Ecto.Migration

  def up do
    drop index(:artifact_links, [:project_id, :relationship_kind, :inserted_at])
    drop constraint(:artifact_links, :artifact_links_relationship_kind_check)

    alter table(:artifact_links) do
      remove :relationship_kind
    end
  end

  def down do
    alter table(:artifact_links) do
      add :relationship_kind, :string, null: false, default: "attached_to"
    end

    create index(:artifact_links, [:project_id, :relationship_kind, :inserted_at])

    create constraint(:artifact_links, :artifact_links_relationship_kind_check,
             check:
               "relationship_kind IN ('attached_to', 'evidence_for', 'produced_by', 'source_for', 'result_of', 'supersedes')"
           )

    alter table(:artifact_links) do
      modify :relationship_kind, :string, null: false, default: nil
    end
  end
end
