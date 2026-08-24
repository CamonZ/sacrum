defmodule Sacrum.Repo.Migrations.AddFactoryNameToWorkflows do
  use Ecto.Migration

  def change do
    alter table(:workflows) do
      add :factory_name, :string
    end
  end
end
