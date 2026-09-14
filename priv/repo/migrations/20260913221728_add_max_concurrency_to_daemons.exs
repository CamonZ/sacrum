defmodule Sacrum.Repo.Migrations.AddMaxConcurrencyToDaemons do
  use Ecto.Migration

  def change do
    alter table(:daemons) do
      add :max_concurrency, :integer
    end

    create constraint(:daemons, :daemons_max_concurrency_positive,
             check: "max_concurrency IS NULL OR max_concurrency > 0"
           )
  end
end
