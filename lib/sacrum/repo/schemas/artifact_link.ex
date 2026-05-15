defmodule Sacrum.Repo.Schemas.ArtifactLink do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @subject_types ~w(task task_section chat_session task_run step_execution)
  @relationship_kinds ~w(produced_by attached_to evidence_for source_for validates supersedes demonstrates)

  @fields ~w(
    artifact_id subject_type subject_id relationship_kind
    project_id user_id metadata
  )a

  schema "artifact_links" do
    field :subject_type, :string
    field :subject_id, Ecto.UUID
    field :relationship_kind, :string
    field :metadata, :map

    belongs_to :artifact, Sacrum.Repo.Schemas.Artifact
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(artifact_link, attrs) do
    artifact_link
    |> cast(attrs, @fields)
    |> validate_required([
      :artifact_id,
      :subject_type,
      :subject_id,
      :relationship_kind,
      :project_id
    ])
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:relationship_kind, @relationship_kinds)
    |> foreign_key_constraint(:artifact_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
  end
end
