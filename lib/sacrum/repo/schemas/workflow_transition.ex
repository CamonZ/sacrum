defmodule Sacrum.Repo.Schemas.WorkflowTransition do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "workflow_transitions" do
    field :label, :string

    belongs_to :from_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :to_workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :target_step, Sacrum.Repo.Schemas.WorkflowStep
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(transition, attrs) do
    transition
    |> cast(attrs, [:label, :from_workflow_id, :to_workflow_id, :target_step_id])
    |> validate_required([:from_workflow_id, :to_workflow_id])
    |> foreign_key_constraint(:from_workflow_id)
    |> foreign_key_constraint(:to_workflow_id)
    |> foreign_key_constraint(:target_step_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:from_workflow_id, :to_workflow_id],
      message: "transition already exists between these workflows"
    )
  end
end
