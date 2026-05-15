defmodule Sacrum.Repo.Migrations.AddNameDescriptionUrlToArtifacts do
  use Ecto.Migration

  def change do
    alter table(:artifacts) do
      add :name, :string
      add :description, :text
      add :url, :string
    end
  end
end
