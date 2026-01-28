defmodule Sacrum.Repo.Schemas.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @create_fields [:title, :description, :level, :priority, :tags]
  @update_fields [
    :title,
    :description,
    :level,
    :priority,
    :tags,
    :needs_human_review,
    :review_comment,
    :started_at,
    :completed_at
  ]

  schema "tasks" do
    field :short_id, :string
    field :title, :string
    field :description, :string
    field :level, :string
    field :priority, :string
    field :tags, {:array, :string}, default: []
    field :needs_human_review, :boolean, default: false
    field :review_comment, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :current_step, Sacrum.Repo.Schemas.WorkflowStep

    has_many :sections, Sacrum.Repo.Schemas.TaskSection
    has_many :code_refs, Sacrum.Repo.Schemas.CodeRef

    timestamps(type: :utc_datetime_usec)
  end

  def create_changeset(task, attrs) do
    task
    |> cast(attrs, @create_fields)
    |> validate_required([:title])
    |> maybe_generate_short_id()
    |> unique_constraint(:short_id)
    |> foreign_key_constraint(:project_id)
  end

  def update_changeset(task, attrs) do
    task
    |> cast(attrs, @update_fields)
    |> validate_required([:title])
  end

  defp maybe_generate_short_id(changeset) do
    case get_field(changeset, :short_id) do
      nil -> put_change(changeset, :short_id, generate_short_id())
      _ -> changeset
    end
  end

  defp generate_short_id do
    "x" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))
  end
end
