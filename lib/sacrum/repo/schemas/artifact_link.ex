defmodule Sacrum.Repo.Schemas.ArtifactLink do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @subject_types ~w(project task task_section workflow task_run step_execution)
  @create_fields ~w(subject_type subject_id logical_name)a
  @update_fields ~w(logical_name)a
  @required_fields ~w(artifact_id project_id user_id subject_type subject_id)a

  schema "artifact_links" do
    field :subject_type, :string
    field :subject_id, :binary_id
    embeds_one :metadata, Sacrum.Repo.Schemas.ArtifactLinkMetadata, on_replace: :delete
    field :logical_name, :string

    belongs_to :artifact, Sacrum.Repo.Schemas.Artifact
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(artifact_link, attrs) do
    artifact_link
    |> cast(attrs, @create_fields, empty_values: [])
    |> validate_required(@required_fields)
    |> validate_inclusion(:subject_type, @subject_types)
    |> cast_embed(:metadata)
    |> validate_logical_name()
    |> foreign_key_constraint(:artifact_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:subject_type, name: :artifact_links_subject_type_check)
    |> unique_constraint(:logical_name, name: :artifact_links_subject_logical_name_index)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(artifact_link, attrs) do
    artifact_link
    |> cast(attrs, @update_fields, empty_values: [])
    |> cast_embed(:metadata)
    |> validate_logical_name()
    |> unique_constraint(:logical_name, name: :artifact_links_subject_logical_name_index)
  end

  defp validate_logical_name(changeset) do
    changeset
    |> validate_length(:logical_name, min: 1, max: 255)
    |> validate_change(:logical_name, fn :logical_name, logical_name ->
      if String.trim(logical_name) == "" do
        [logical_name: "can't be blank"]
      else
        []
      end
    end)
  end
end
