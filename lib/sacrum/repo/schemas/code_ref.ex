defmodule Sacrum.Repo.Schemas.CodeRef do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @fields [:path, :line_start, :line_end, :name, :description, :order_index]

  schema "code_refs" do
    field :path, :string
    field :line_start, :integer
    field :line_end, :integer
    field :name, :string
    field :description, :string
    field :order_index, :integer

    belongs_to :task, Sacrum.Repo.Schemas.Task
    belongs_to :section, Sacrum.Repo.Schemas.TaskSection
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(code_ref, attrs) do
    code_ref
    |> cast(attrs, @fields)
    |> validate_required([:path])
    |> validate_number(:order_index, greater_than_or_equal_to: 0)
    |> validate_exactly_one_parent()
    |> check_constraint(:task_id,
      name: :exactly_one_parent,
      message: "exactly one of task_id or section_id must be set"
    )
    |> foreign_key_constraint(:project_id)
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
