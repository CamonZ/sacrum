defmodule Sacrum.Repo.Schemas.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :description, :string

    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new project.
  Auto-generates slug from name if slug is not provided.
  """
  def create_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :description])
    |> validate_required([:name])
    |> maybe_generate_slug()
    |> validate_slug()
    |> unique_constraint([:user_id, :slug],
      error_key: :slug,
      message: "has already been taken for this user"
    )
  end

  @doc """
  Changeset for updating a project.
  """
  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :description])
    |> validate_slug_if_changed()
    |> unique_constraint([:user_id, :slug],
      error_key: :slug,
      message: "has already been taken for this user"
    )
  end

  defp maybe_generate_slug(changeset) do
    case get_field(changeset, :slug) do
      nil -> put_change(changeset, :slug, slugify(get_field(changeset, :name)))
      "" -> put_change(changeset, :slug, slugify(get_field(changeset, :name)))
      _slug -> changeset
    end
  end

  defp validate_slug_if_changed(changeset) do
    if get_change(changeset, :slug) do
      validate_slug(changeset)
    else
      changeset
    end
  end

  defp validate_slug(changeset) do
    changeset
    |> validate_required([:slug])
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$|^[a-z0-9]$/,
      message: "must be lowercase alphanumeric with hyphens, cannot start or end with a hyphen"
    )
    |> validate_length(:slug, min: 1, max: 100)
  end

  defp slugify(nil), do: nil

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
