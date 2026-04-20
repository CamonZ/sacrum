defmodule Sacrum.Repo.Schemas.StepExecution do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "step_executions" do
    field :step_name, :string
    field :status, :string
    field :context, :map, default: %{}
    field :prompt, :string
    field :output, :string
    field :transition_result, :string
    field :model, :string
    field :model_provider, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cost, :decimal
    field :duration_ms, :integer
    field :handoff, :map

    belongs_to :task, Sacrum.Repo.Schemas.Task
    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :step, Sacrum.Repo.Schemas.WorkflowStep
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :session_logs, Sacrum.Repo.Schemas.SessionLog

    timestamps(type: :utc_datetime_usec)
  end

  @create_fields ~w(task_id step_name status context prompt output transition_result model model_provider input_tokens output_tokens cost duration_ms workflow_id step_id handoff)a
  @update_fields ~w(step_name status context prompt output transition_result model model_provider input_tokens output_tokens cost duration_ms handoff)a

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(execution, attrs) do
    execution
    |> cast(attrs, @create_fields)
    |> validate_required([:task_id, :step_name])
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:step_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint([:task_id, :workflow_id, :step_id],
      name: "idx_step_executions_entered_unique",
      message: "only one entered execution per task/workflow/step"
    )
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(execution, attrs) do
    execution
    |> cast(attrs, @update_fields)
    |> validate_required([:step_name])
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:project_id)
  end
end
