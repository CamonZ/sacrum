defmodule Sacrum.Repo.Schemas.Project do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @key_prefix_format ~r/^[A-Z][A-Z0-9]{0,9}$/
  @key_prefix_format_message "must be 1-10 uppercase letters or digits, starting with a letter"
  @key_prefix_immutable_message "cannot be changed after task identifiers have been issued"

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :description, :string
    # Prefix of human-readable task keys (`VTB-1`). Unset until the user chooses
    # one; setting it enables task numbering, after which it is immutable.
    field :key_prefix, :string
    # Last task number issued in this project; maintained by the database.
    field :last_task_number, :integer, default: 0, read_after_writes: true

    belongs_to :user, Sacrum.Repo.Schemas.User
    has_many :workflows, Sacrum.Repo.Schemas.Workflow
    has_many :tasks, Sacrum.Repo.Schemas.Task

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new project.
  Auto-generates slug from name if slug is not provided.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :description, :key_prefix])
    |> validate_required([:name])
    |> maybe_generate_slug()
    |> validate_slug()
    |> validate_key_prefix()
    |> unique_constraint([:user_id, :slug],
      error_key: :slug,
      message: "has already been taken for this user"
    )
  end

  @doc """
  Changeset for updating a project.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :description, :key_prefix])
    |> validate_slug_if_changed()
    |> validate_key_prefix()
    |> validate_key_prefix_unissued()
    |> unique_constraint([:user_id, :slug],
      error_key: :slug,
      message: "has already been taken for this user"
    )
  end

  @doc "Composes the human-readable key of a task number within this project."
  @spec task_key(t() | String.t() | nil, integer() | nil) :: String.t() | nil
  def task_key(%__MODULE__{key_prefix: prefix}, number), do: task_key(prefix, number)

  def task_key(prefix, number) when is_binary(prefix) and is_integer(number),
    do: "#{prefix}-#{number}"

  def task_key(_prefix, _number), do: nil

  defp validate_key_prefix(changeset) do
    changeset
    |> update_change(:key_prefix, &upcase_key_prefix/1)
    |> validate_format(:key_prefix, @key_prefix_format, message: @key_prefix_format_message)
    |> check_constraint(:key_prefix,
      name: :projects_key_prefix_format,
      message: @key_prefix_format_message
    )
    |> check_constraint(:key_prefix,
      name: :projects_key_prefix_immutable,
      message: @key_prefix_immutable_message
    )
  end

  defp upcase_key_prefix(prefix) when is_binary(prefix), do: String.upcase(prefix)
  defp upcase_key_prefix(prefix), do: prefix

  defp validate_key_prefix_unissued(changeset) do
    issued? = changeset.data.key_prefix != nil and (changeset.data.last_task_number || 0) > 0

    if issued? and Map.has_key?(changeset.changes, :key_prefix) do
      add_error(changeset, :key_prefix, @key_prefix_immutable_message)
    else
      changeset
    end
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
