defmodule Sacrum.Repo.Schemas.SessionLog do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "session_logs" do
    field :content, :string

    belongs_to :step_execution, Sacrum.Repo.Schemas.StepExecution
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(log, attrs) do
    log
    |> cast(attrs, [:content, :step_execution_id])
    |> validate_required([:content, :step_execution_id])
    |> foreign_key_constraint(:step_execution_id)
    |> foreign_key_constraint(:project_id)
  end
end
