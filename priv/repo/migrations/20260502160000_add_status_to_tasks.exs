defmodule Sacrum.Repo.Migrations.AddStatusToTasks do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :status, :string, null: false, default: "ready"
    end

    create constraint(:tasks, :status_must_be_valid,
             check: "status IN ('ready', 'running', 'waiting', 'done')"
           )

    create index(:tasks, [:status])
  end
end
