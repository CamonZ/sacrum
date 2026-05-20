defmodule Sacrum.Repo.Schemas.SessionLog do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @supported_formats ["openai", "anthropic"]
  @default_format "anthropic"

  schema "session_logs" do
    field :content, :string
    field :format, :string, default: @default_format

    belongs_to :step_execution, Sacrum.Repo.Schemas.StepExecution
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec supported_formats() :: [String.t()]
  def supported_formats, do: @supported_formats

  @spec default_format() :: String.t()
  def default_format, do: @default_format

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(log, attrs) do
    log
    |> cast(attrs, [:content, :format, :step_execution_id])
    |> validate_required([:content, :format, :step_execution_id])
    |> validate_inclusion(:format, @supported_formats)
    |> foreign_key_constraint(:step_execution_id)
    |> foreign_key_constraint(:project_id)
    |> check_constraint(:format, name: :session_logs_format_check)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(log, attrs) do
    log
    |> cast(attrs, [:content])
    |> validate_required([:content])
  end
end
