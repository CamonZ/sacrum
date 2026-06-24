defmodule Sacrum.Repo.Migrations.AddOrderIndexToCodeRefs do
  use Ecto.Migration

  def change do
    alter table(:code_refs) do
      add :order_index, :integer, null: false, default: 0
    end
  end
end
