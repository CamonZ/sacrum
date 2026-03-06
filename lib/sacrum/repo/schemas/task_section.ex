defmodule Sacrum.Repo.Schemas.TaskSection do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @fields [:section_type, :content, :section_order, :done, :done_at]

  schema "task_sections" do
    field :section_type, :string
    field :content, :string
    field :section_order, :integer
    field :done, :boolean, default: false
    field :done_at, :utc_datetime_usec

    belongs_to :task, Sacrum.Repo.Schemas.Task
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User
    has_many :code_refs, Sacrum.Repo.Schemas.CodeRef, foreign_key: :section_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(section, attrs) do
    section
    |> cast(attrs, @fields)
    |> validate_required([:section_type, :content])
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:project_id)
  end
end
