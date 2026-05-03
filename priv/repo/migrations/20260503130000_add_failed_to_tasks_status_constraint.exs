defmodule Sacrum.Repo.Migrations.AddFailedToTasksStatusConstraint do
  use Ecto.Migration

  def up do
    drop constraint(:tasks, :status_must_be_valid)

    create constraint(:tasks, :status_must_be_valid,
             check: "status IN ('ready', 'running', 'waiting', 'done', 'failed')"
           )
  end

  def down do
    drop constraint(:tasks, :status_must_be_valid)

    create constraint(:tasks, :status_must_be_valid,
             check: "status IN ('ready', 'running', 'waiting', 'done')"
           )
  end
end
