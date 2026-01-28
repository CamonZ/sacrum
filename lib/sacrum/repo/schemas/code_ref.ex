defmodule Sacrum.Repo.Schemas.CodeRef do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @fields [:path, :line_start, :line_end, :name, :description]

  schema "code_refs" do
    field :path, :string
    field :line_start, :integer
    field :line_end, :integer
    field :name, :string
    field :description, :string

    belongs_to :task, Sacrum.Repo.Schemas.Task
    belongs_to :section, Sacrum.Repo.Schemas.TaskSection

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(code_ref, attrs) do
    code_ref
    |> cast(attrs, @fields)
    |> validate_required([:path])
    |> validate_exactly_one_parent()
    |> check_constraint(:task_id,
      name: :exactly_one_parent,
      message: "exactly one of task_id or section_id must be set"
    )
  end

  defp validate_exactly_one_parent(changeset) do
    task_id = get_field(changeset, :task_id)
    section_id = get_field(changeset, :section_id)

    case {task_id, section_id} do
      {nil, nil} ->
        add_error(changeset, :task_id, "exactly one of task_id or section_id must be set")

      {_, nil} ->
        changeset

      {nil, _} ->
        changeset

      {_, _} ->
        add_error(changeset, :task_id, "exactly one of task_id or section_id must be set")
    end
  end
end
