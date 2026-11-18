defmodule Sacrum.Repo.Migrations.RemoveReviewThreadsMutationId do
  use Ecto.Migration

  def change do
    alter table(:review_threads) do
      remove :mutation_id, :uuid, null: false, default: fragment("gen_random_uuid()")
    end
  end
end
