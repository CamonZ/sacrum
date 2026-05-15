defmodule Sacrum.Repo.Schemas.ArtifactDecision do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @decision_kinds ~w(approved rejected rejected_with_comments needs_revision pending_review)

  @fields ~w(
    artifact_id subject_type subject_id decision_kind
    decided_by_user_id comments metadata
  )a

  schema "artifact_decisions" do
    field :subject_type, :string
    field :subject_id, Ecto.UUID
    field :decision_kind, :string
    field :comments, :string
    field :metadata, :map

    belongs_to :artifact, Sacrum.Repo.Schemas.Artifact
    belongs_to :decided_by_user, Sacrum.Repo.Schemas.User, foreign_key: :decided_by_user_id

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(decision, attrs) do
    decision
    |> cast(attrs, @fields)
    |> validate_required([:artifact_id, :decision_kind, :decided_by_user_id])
    |> validate_inclusion(:decision_kind, @decision_kinds)
    |> foreign_key_constraint(:artifact_id)
    |> foreign_key_constraint(:decided_by_user_id)
  end
end
