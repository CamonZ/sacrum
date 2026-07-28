defmodule Sacrum.Repo.Schemas.Artifact do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @artifact_fields ~w(filename body)a
  @required_fields ~w(project_id user_id filename body)a

  schema "artifacts" do
    field :filename, :string
    field :body, :string

    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, @artifact_fields)
    |> validate_required(@required_fields)
    |> validate_length(:filename, max: 255)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(artifact, attrs) do
    artifact
    |> cast(attrs, @artifact_fields)
    |> validate_required(@artifact_fields)
    |> validate_length(:filename, max: 255)
  end
end
