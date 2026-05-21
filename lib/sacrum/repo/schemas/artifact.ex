defmodule Sacrum.Repo.Schemas.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @artifact_states ~w(draft pending_approval approved applied rejected)
  @visibilities ~w(public internal)
  @redaction_states ~w(not_needed redacted blocked)

  @create_fields ~w(
    artifact_type artifact_state visibility redaction_state title content data storage_ref
  )a
  @update_fields ~w(
    artifact_state visibility redaction_state title content data storage_ref
  )a
  @required_fields ~w(project_id user_id artifact_type artifact_state visibility redaction_state)a

  schema "artifacts" do
    field :artifact_type, :string
    field :artifact_state, :string
    field :visibility, :string
    field :redaction_state, :string
    field :title, :string
    field :content, :string
    field :data, :map, default: %{}
    field :storage_ref, :string

    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
    |> validate_artifact_enums()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, @update_fields)
    |> validate_artifact_enums()
  end

  defp validate_artifact_enums(changeset) do
    changeset
    |> validate_inclusion(:artifact_state, @artifact_states)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_inclusion(:redaction_state, @redaction_states)
    |> check_constraint(:artifact_state, name: :artifacts_artifact_state_check)
    |> check_constraint(:visibility, name: :artifacts_visibility_check)
    |> check_constraint(:redaction_state, name: :artifacts_redaction_state_check)
  end
end
