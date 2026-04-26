defmodule Sacrum.Repo.Schemas.User do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "users" do
    field :email, :string
    field :username, :string
    field :name, :string
    field :password_hash, :string
    field :google_sub, :string
    field :avatar_url, :string
    field :onboarded_at, :utc_datetime_usec

    field :password, :string, virtual: true, redact: true

    has_many :api_tokens, Sacrum.Repo.Schemas.ApiToken
    has_many :projects, Sacrum.Repo.Schemas.Project
    has_many :invites_created, Sacrum.Repo.Schemas.Invite, foreign_key: :invited_by_id

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new user.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :name, :password])
    |> validate_required([:email, :username, :password])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "must contain only letters, numbers, and underscores"
    )
    |> validate_length(:password, min: 8)
    |> unique_constraint(:email)
    |> unique_constraint(:username)
    |> hash_password()
  end

  @doc """
  Changeset for updating user profile fields.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :name])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-zA-Z0-9_]+$/,
      message: "must contain only letters, numbers, and underscores"
    )
    |> unique_constraint(:email)
    |> unique_constraint(:username)
  end

  @doc """
  Changeset for changing password.
  """
  @spec password_changeset(t(), map()) :: Ecto.Changeset.t()
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8)
    |> hash_password()
  end

  @doc """
  Changeset for creating a user via Google OAuth.
  """
  @spec oauth_changeset(t(), map()) :: Ecto.Changeset.t()
  def oauth_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :google_sub, :avatar_url])
    |> validate_required([:email, :google_sub])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> unique_constraint(:email)
    |> unique_constraint(:google_sub)
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:password_hash, Argon2.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end

  @doc """
  Verifies the password against the stored hash.
  """
  @spec valid_password?(t(), String.t()) :: boolean()
  def valid_password?(%__MODULE__{password_hash: hash}, password)
      when is_binary(hash) and byte_size(password) > 0 do
    Argon2.verify_pass(password, hash)
  end

  def valid_password?(_, _), do: Argon2.no_user_verify()
end
