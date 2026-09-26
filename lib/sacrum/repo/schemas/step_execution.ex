defmodule Sacrum.Repo.Schemas.StepExecution do
  use Ecto.Schema
  import Ecto.Changeset
  import PolymorphicEmbed

  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @step_types Sacrum.Repo.Schemas.WorkflowStep.step_types()

  schema "step_executions" do
    field :step_name, :string
    field :step_type, Ecto.Enum, values: @step_types, default: :llm_inference
    field :status, :string
    field :context, :map, default: %{}

    # The step's config as this execution used it, with templates rendered.
    # Written by the server at dispatch; never cast from client attrs.
    polymorphic_embeds_one(:config,
      types: Config.types(),
      use_parent_field_for_type: :step_type,
      on_replace: :update
    )

    field :output, :string
    field :transition_result, :string
    field :model, :string
    field :model_provider, :string
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :session_input_tokens, :integer
    field :session_cache_read_input_tokens, :integer
    field :session_output_tokens, :integer
    field :session_total_tokens, :integer
    field :context_window_input_tokens, :integer
    field :context_window_cache_read_input_tokens, :integer
    field :context_window_total_tokens, :integer
    field :cost, :decimal
    field :duration_ms, :integer
    field :handoff, :map

    belongs_to :task_run, Sacrum.Repo.Schemas.TaskRun
    belongs_to :task, Sacrum.Repo.Schemas.Task
    belongs_to :workflow, Sacrum.Repo.Schemas.Workflow
    belongs_to :step, Sacrum.Repo.Schemas.WorkflowStep
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :session_logs, Sacrum.Repo.Schemas.SessionLog

    timestamps(type: :utc_datetime_usec)
  end

  @token_fields ~w(input_tokens output_tokens session_input_tokens session_cache_read_input_tokens session_output_tokens session_total_tokens context_window_input_tokens context_window_cache_read_input_tokens context_window_total_tokens)a
  @create_fields ~w(task_id task_run_id step_name step_type status context output transition_result model model_provider cost duration_ms workflow_id step_id handoff)a ++
                   @token_fields
  @update_fields ~w(task_run_id step_name status context output transition_result model model_provider cost duration_ms handoff)a ++
                   @token_fields

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(execution, attrs) do
    execution
    |> cast(attrs, @create_fields)
    |> validate_required([:task_id, :step_name, :step_type])
    |> foreign_key_constraint(:task_run_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:step_id)
    |> foreign_key_constraint(:project_id)
  end

  @doc "Records the rendered config an execution runs with."
  @spec put_config(Ecto.Changeset.t(), Config.t()) :: Ecto.Changeset.t()
  def put_config(changeset, config), do: put_change(changeset, :config, config)

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(execution, attrs) do
    execution
    |> cast(attrs, @update_fields)
    |> validate_required([:step_name])
    |> foreign_key_constraint(:task_run_id)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:project_id)
  end
end
