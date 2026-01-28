defmodule Sacrum.Repo.Schemas.TaskDependency do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "task_dependencies" do
    belongs_to :task, Sacrum.Repo.Schemas.Task
    belongs_to :depends_on, Sacrum.Repo.Schemas.Task

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(dep, attrs \\ %{}) do
    dep
    |> cast(attrs, [])
    |> unique_constraint([:task_id, :depends_on_id], message: "dependency already exists")
    |> check_constraint(:task_id,
      name: :no_self_dependency,
      message: "a task cannot depend on itself"
    )
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:depends_on_id)
  end
end
