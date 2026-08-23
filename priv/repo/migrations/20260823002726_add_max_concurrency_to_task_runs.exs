defmodule Sacrum.Repo.Migrations.AddMaxConcurrencyToTaskRuns do
  use Ecto.Migration

  def change do
    alter table(:task_runs) do
      add :max_concurrency, :integer
    end

    create constraint(:task_runs, :task_runs_max_concurrency_positive,
             check: "max_concurrency IS NULL OR max_concurrency > 0"
           )
  end
end
