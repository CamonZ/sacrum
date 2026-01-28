defmodule Sacrum.Repo.Schemas.TaskHierarchy do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_hierarchy" do
    belongs_to :parent, Sacrum.Repo.Schemas.Task
    belongs_to :child, Sacrum.Repo.Schemas.Task

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(hierarchy, attrs \\ %{}) do
    hierarchy
    |> cast(attrs, [])
    |> unique_constraint(:child_id, message: "task already has a parent")
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:child_id)
  end
end
