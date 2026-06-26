defmodule Sacrum.Repo.Schemas.ArtifactLink do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @subject_types ~w(task task_section workflow task_run step_execution)
  @relationship_kinds ~w(attached_to evidence_for produced_by source_for result_of supersedes)

  @create_fields ~w(subject_type subject_id relationship_kind metadata)a
  @update_fields ~w(metadata)a
  @required_fields ~w(artifact_id project_id user_id subject_type subject_id relationship_kind)a

  schema "artifact_links" do
    field :subject_type, :string
    field :subject_id, :binary_id
    field :relationship_kind, :string
    field :metadata, :map, default: %{}

    belongs_to :artifact, Sacrum.Repo.Schemas.Artifact
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(artifact_link, attrs) do
    artifact_link
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:subject_type, @subject_types)
    |> validate_inclusion(:relationship_kind, @relationship_kinds)
    |> foreign_key_constraint(:artifact_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:subject_type, name: :artifact_links_subject_type_check)
    |> check_constraint(:relationship_kind, name: :artifact_links_relationship_kind_check)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(artifact_link, attrs) do
    cast(artifact_link, attrs, @update_fields)
  end
end
