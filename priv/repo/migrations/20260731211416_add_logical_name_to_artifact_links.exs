defmodule Sacrum.Repo.Migrations.AddLogicalNameToArtifactLinks do
  use Ecto.Migration

  def change do
    alter table(:artifact_links) do
      add :logical_name, :string
    end

    create unique_index(
             :artifact_links,
             [:user_id, :project_id, :subject_type, :subject_id, :logical_name],
             where: "logical_name IS NOT NULL",
             name: :artifact_links_subject_logical_name_index
           )
  end
end
