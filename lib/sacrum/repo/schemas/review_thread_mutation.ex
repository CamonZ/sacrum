defmodule Sacrum.Repo.Schemas.ReviewThreadMutation do
  @moduledoc "Receipt for an accepted review-thread mutation."

  use Ecto.Schema

  @primary_key false
  schema "review_thread_mutations" do
    field :user_id, :binary_id, primary_key: true
    field :project_id, :binary_id, primary_key: true
    field :installation_id, :binary_id, primary_key: true
    field :thread_id, :binary_id, primary_key: true
    field :mutation_id, :binary_id, primary_key: true
  end
end
