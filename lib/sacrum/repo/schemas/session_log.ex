defmodule Sacrum.Repo.Schemas.SessionLog do
  alias Sacrum.Accounts.SessionLogs.HarnessEventV1
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @supported_formats ["harness"]
  @default_format "harness"
  @max_logical_key_length 255

  schema "session_logs" do
    field :content, :string
    field :format, :string, default: @default_format
    field :logical_key, :string

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
    |> cast(attrs, [:content, :format, :logical_key])
    |> validate_required([:content, :format, :step_execution_id, :logical_key])
    |> validate_length(:logical_key, max: @max_logical_key_length)
    |> validate_inclusion(:format, @supported_formats)
    |> validate_harness_event()
    |> unique_constraint([:step_execution_id, :logical_key],
      name: :session_logs_step_execution_id_logical_key_index
    )
    |> foreign_key_constraint(:step_execution_id)
    |> foreign_key_constraint(:project_id)
    |> check_constraint(:format, name: :session_logs_format_check)
    |> check_constraint(:logical_key, name: :session_logs_logical_key_check)
  end

  defp validate_harness_event(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_harness_event(changeset) do
    case HarnessEventV1.decode(
           get_field(changeset, :content),
           get_field(changeset, :logical_key)
         ) do
      {:ok, _event} ->
        changeset

      :error ->
        add_error(changeset, :content, "must be a valid harness event matching logical_key")
    end
  end
end
