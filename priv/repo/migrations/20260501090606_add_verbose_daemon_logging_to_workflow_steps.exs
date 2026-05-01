defmodule Sacrum.Repo.Migrations.AddVerboseDaemonLoggingToWorkflowSteps do
  use Ecto.Migration

  def change do
    alter table(:workflow_steps) do
      add :verbose_daemon_logging, :boolean, default: false, null: false
    end
  end
end
