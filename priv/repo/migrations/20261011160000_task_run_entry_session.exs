defmodule Sacrum.Repo.Migrations.TaskRunEntrySession do
  @moduledoc """
  Holds the session directive a TaskRun's first dispatch enters with when the
  conversation lives in a directly linked run: the run that stopped at a stop
  step, or a child run's parent. Set only by the engine; null means the first
  dispatch follows its own route or transition directive.
  """

  use Ecto.Migration

  def change do
    alter table(:task_runs) do
      add :entry_session, :map
    end
  end
end
