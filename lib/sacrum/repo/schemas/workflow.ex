defmodule Sacrum.Repo.Schemas.Workflow do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflows" do
    field :name, :string
    field :description, :string
    field :initial_step_id, :binary_id
    field :metadata, :map, default: %{}
    field :auto_advance, :boolean, default: false
    field :display_order, :integer
    field :is_default, :boolean, default: false
    field :kanban_column, :string

    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :on_done_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :on_reject_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :user, Sacrum.Repo.Schemas.User
    has_many :workflow_steps, Sacrum.Repo.Schemas.WorkflowStep
    has_many :transitions, Sacrum.Repo.Schemas.WorkflowTransition, foreign_key: :from_workflow_id

    timestamps(type: :utc_datetime_usec)
  end

  @create_fields ~w(name description metadata auto_advance display_order is_default kanban_column user_id)a
  @update_fields ~w(name description metadata auto_advance display_order is_default initial_step_id on_done_workflow_id on_reject_workflow_id kanban_column)a

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(workflow, attrs) do
    workflow
    |> cast(attrs, @create_fields)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 255)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:workflows_unique_default_per_project)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(workflow, attrs) do
    workflow
    |> cast(attrs, @update_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> foreign_key_constraint(:initial_step_id)
    |> foreign_key_constraint(:on_done_workflow_id)
    |> foreign_key_constraint(:on_reject_workflow_id)
    |> unique_constraint(:workflows_unique_default_per_project)
  end
end
