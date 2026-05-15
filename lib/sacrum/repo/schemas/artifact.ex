defmodule Sacrum.Repo.Schemas.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @visibilities ~w(public internal)
  @artifact_states ~w(draft pending_approval approved applied rejected)
  @redaction_states ~w(not_needed redacted blocked)

  @fields ~w(
    project_id user_id artifact_type artifact_state title content
    name description url data storage_ref visibility redaction_state
  )a

  schema "artifacts" do
    field :artifact_type, :string
    field :artifact_state, :string
    field :title, :string
    field :content, :string
    field :name, :string
    field :description, :string
    field :url, :string
    field :data, :map
    field :storage_ref, :string
    field :visibility, :string
    field :redaction_state, :string, default: "not_needed"

    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :links, Sacrum.Repo.Schemas.ArtifactLink
    has_many :decisions, Sacrum.Repo.Schemas.ArtifactDecision

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(artifact, attrs) do
    artifact
    |> cast(attrs, @fields)
    |> validate_required([
      :project_id,
      :user_id,
      :artifact_type,
      :artifact_state,
      :title,
      :visibility
    ])
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_inclusion(:artifact_state, @artifact_states)
    |> validate_inclusion(:redaction_state, @redaction_states)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
  end
end
