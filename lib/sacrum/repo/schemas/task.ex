defmodule Sacrum.Repo.Schemas.Task do
  use Ecto.Schema
  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.TaskDependency
  alias Sacrum.Repo.Schemas.TaskSection

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @create_fields [:title, :description, :level, :priority, :tags, :worktree, :track, :parent_id]
  @update_fields [
    :title,
    :description,
    :level,
    :priority,
    :tags,
    :needs_human_review,
    :review_comment,
    :started_at,
    :completed_at,
    :revision_feedback,
    :worktree,
    :track,
    :archived
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
    field :rejection_reason, :string
    field :revision_feedback, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :worktree, :string
    field :track, :string
    field :archived, :boolean, default: false

    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :current_step, Sacrum.Repo.Schemas.WorkflowStep
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :sections, Sacrum.Repo.Schemas.TaskSection, on_replace: :delete
    has_many :code_refs, Sacrum.Repo.Schemas.CodeRef
    has_many :step_executions, Sacrum.Repo.Schemas.StepExecution

    # Dependencies (blockers — tasks this task depends on)
    has_many :task_dependencies, TaskDependency, foreign_key: :task_id
    has_many :blockers, through: [:task_dependencies, :depends_on]

    # Dependencies (dependents — tasks that depend on this one)
    has_many :task_dependents, TaskDependency, foreign_key: :depends_on_id
    has_many :dependents, through: [:task_dependents, :task]

    # Hierarchy (parent)
    belongs_to :parent, Sacrum.Repo.Schemas.Task

    # Hierarchy (children)
    has_many :children, Sacrum.Repo.Schemas.Task, foreign_key: :parent_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(task, attrs) do
    user_id = task.user_id
    project_id = task.project_id

    task
    |> cast(attrs, @create_fields)
    |> validate_required([:title])
    |> cast_assoc(:sections,
      with: fn section, section_attrs ->
        section
        |> TaskSection.changeset(section_attrs)
        |> Ecto.Changeset.put_change(:user_id, user_id)
        |> Ecto.Changeset.put_change(:project_id, project_id)
      end
    )
    |> maybe_generate_short_id()
    |> unique_constraint(:short_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:parent_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(task, attrs) do
    user_id = task.user_id
    project_id = task.project_id

    task
    |> cast(attrs, @update_fields)
    |> validate_required([:title])
    |> cast_assoc(:sections,
      with: fn section, section_attrs ->
        section
        |> TaskSection.changeset(section_attrs)
        |> Ecto.Changeset.put_change(:user_id, user_id)
        |> Ecto.Changeset.put_change(:project_id, project_id)
      end
    )
  end

  defp maybe_generate_short_id(changeset) do
    case get_field(changeset, :short_id) do
      nil -> put_change(changeset, :short_id, generate_short_id())
      _ -> changeset
    end
  end

  defp generate_short_id do
    "x" <> Base.encode16(:crypto.strong_rand_bytes(3), case: :lower)
  end
end
