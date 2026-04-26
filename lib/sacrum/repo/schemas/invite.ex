defmodule Sacrum.Repo.Schemas.Invite do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "invites" do
    field :email, :string
    field :accepted_at, :utc_datetime_usec

    belongs_to :invited_by, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(invite, attrs) do
    invite
    |> cast(attrs, [:email, :invited_by_id])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> unique_constraint(:email)
  end

  @spec accept_changeset(t()) :: Ecto.Changeset.t()
  def accept_changeset(invite) do
    change(invite, accepted_at: DateTime.utc_now(:second))
  end
end
