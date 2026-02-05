defmodule Sacrum.Repo.Schemas.StepExecution do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "step_executions" do
    field :task_id, :binary_id
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

    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @create_fields ~w(task_id step_name status context prompt output transition_result model model_provider input_tokens output_tokens cost duration_ms workflow_id)a

  def create_changeset(execution, attrs) do
    execution
    |> cast(attrs, @create_fields)
    |> validate_required([:task_id, :step_name])
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:project_id)
  end
end
