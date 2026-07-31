defmodule Sacrum.Repo.Schemas.ArtifactLinkMetadata do
  @moduledoc """
  Versioned, self-describing metadata for an artifact attachment.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key false
  @fields ~w(version content_kind format origin presentation extensions)a
  @derive {Jason.Encoder, only: @fields}

  embedded_schema do
    field :version, :integer
    field :content_kind, :string
    field :format, :string
    field :origin, :string
    field :presentation, :string
    field :extensions, :map
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(metadata, attrs) do
    metadata
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:version, [1])
    |> validate_nonempty_strings([:content_kind, :format, :origin, :presentation])
  end

  defp validate_nonempty_strings(changeset, fields) do
    Enum.reduce(fields, changeset, &validate_nonempty_string/2)
  end

  defp validate_nonempty_string(field, changeset) do
    validate_change(changeset, field, &nonempty_string_error/2)
  end

  defp nonempty_string_error(field, value) do
    if String.trim(value) == "", do: [{field, "can't be blank"}], else: []
  end
end
