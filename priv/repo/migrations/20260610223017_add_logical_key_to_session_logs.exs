defmodule Sacrum.Repo.Migrations.AddLogicalKeyToSessionLogs do
  use Ecto.Migration

  def change do
    alter table(:session_logs) do
      add :logical_key, :string
    end

    create unique_index(:session_logs, [:step_execution_id, :logical_key],
             name: :session_logs_step_execution_id_logical_key_index,
             where: "logical_key IS NOT NULL"
           )
  end
end
