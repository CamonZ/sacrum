defmodule Sacrum.Repo.Schemas.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "api_tokens" do
    field :token_hash, :string
    field :name, :string
    field :token_type, :string, default: "api_token"
    field :scopes, {:array, :string}, default: []
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new API token.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(api_token, attrs) do
    api_token
    |> cast(attrs, [:token_hash, :name, :token_type, :scopes, :expires_at, :user_id])
    |> validate_required([:token_hash, :user_id])
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Changeset for updating last_used_at timestamp.
  """
  @spec touch_changeset(t()) :: Ecto.Changeset.t()
  def touch_changeset(api_token) do
    change(api_token, last_used_at: DateTime.utc_now())
  end
end
