defmodule Sacrum.Repo.Schemas.TaskRun do
  use Ecto.Schema
  import Ecto.Changeset

  alias Sacrum.TaskRuns.Status, as: TaskRunStatus

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses TaskRunStatus.values()

  @create_fields ~w(
    task_id project_id user_id status started_at ended_at stop_requested_at
    latest_step_execution_id failure_kind failure_reason failure_context outcome_kind
    outcome_context parent_task_run_id root_task_run_id triggered_by_step_execution_id
  )a

  @update_fields ~w(
    status ended_at stop_requested_at latest_step_execution_id failure_kind failure_reason
    failure_context outcome_kind outcome_context
  )a

  schema "task_runs" do
    field :status, Ecto.Enum, values: @statuses, default: :executing
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :stop_requested_at, :utc_datetime_usec
    field :failure_kind, :string
    field :failure_reason, :string
    field :failure_context, :map, default: %{}
    field :outcome_kind, :string
    field :outcome_context, :map, default: %{}

    belongs_to :task, Sacrum.Repo.Schemas.Task
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    belongs_to :latest_step_execution, Sacrum.Repo.Schemas.StepExecution
    belongs_to :parent_task_run, __MODULE__, foreign_key: :parent_task_run_id, references: :id
    belongs_to :root_task_run, __MODULE__, foreign_key: :root_task_run_id, references: :id
    belongs_to :triggered_by_step_execution, Sacrum.Repo.Schemas.StepExecution

    has_many :child_task_runs, __MODULE__, foreign_key: :parent_task_run_id, references: :id
    has_many :step_executions, Sacrum.Repo.Schemas.StepExecution

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(task_run, attrs) do
    task_run
    |> cast(attrs, @create_fields)
    |> put_started_at()
    |> validate_required([:task_id, :project_id, :user_id, :status, :started_at])
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:latest_step_execution_id)
    |> foreign_key_constraint(:parent_task_run_id)
    |> foreign_key_constraint(:root_task_run_id)
    |> foreign_key_constraint(:triggered_by_step_execution_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(task_run, attrs) do
    task_run
    |> cast(attrs, @update_fields)
    |> validate_required([:status])
    |> foreign_key_constraint(:latest_step_execution_id)
  end

  defp put_started_at(changeset) do
    case get_field(changeset, :started_at) do
      nil -> put_change(changeset, :started_at, DateTime.utc_now())
      _started_at -> changeset
    end
  end
end
