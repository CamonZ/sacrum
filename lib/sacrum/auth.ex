defmodule Sacrum.Auth do
  @moduledoc """
  The Auth context handles API token authentication.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.ApiTokens
  alias Sacrum.Repo.Schemas.{ApiToken, User}

  @token_bytes 32

  @doc """
  Creates a new API token for a user.
  Returns the plaintext token only once - it's not stored in the database.

  ## Examples

      iex> create_api_token(user, %{name: "My API Token"})
      {:ok, "sac_abc123...", %ApiToken{}}
  """
  def create_api_token(%User{id: user_id}, attrs \\ %{}) do
    plaintext_token = generate_token()
    token_hash = hash_token(plaintext_token)

    attrs =
      attrs
      |> Map.put(:token_hash, token_hash)
      |> Map.put(:user_id, user_id)

    case ApiTokens.insert(attrs) do
      {:ok, api_token} -> {:ok, plaintext_token, api_token}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Verifies a token and returns the associated user.

  ## Examples

      iex> verify_token("sac_valid_token")
      {:ok, %User{}}

      iex> verify_token("sac_invalid_token")
      {:error, :invalid}

      iex> verify_token("sac_expired_token")
      {:error, :expired}
  """
  def verify_token(plaintext_token) when is_binary(plaintext_token) do
    token_hash = hash_token(plaintext_token)

    query =
      from t in ApiToken,
        where: t.token_hash == ^token_hash,
        preload: [:user]

    case Repo.one(query) do
      nil ->
        {:error, :invalid}

      %ApiToken{expires_at: expires_at} = token when not is_nil(expires_at) ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:ok, token.user}
        else
          {:error, :expired}
        end

      %ApiToken{user: user} ->
        {:ok, user}
    end
  end

  def verify_token(_), do: {:error, :invalid}

  @doc """
  Updates the last_used_at timestamp for a token.
  """
  def update_token_last_used(plaintext_token) when is_binary(plaintext_token) do
    token_hash = hash_token(plaintext_token)

    Repo.update_all(
      from(t in ApiToken, where: t.token_hash == ^token_hash),
      set: [last_used_at: DateTime.utc_now()]
    )

    :ok
  end

  defp generate_token do
    random_bytes = :crypto.strong_rand_bytes(@token_bytes)
    "sac_" <> Base.url_encode64(random_bytes, padding: false)
  end

  defp hash_token(token) do
    Base.encode64(:crypto.hash(:sha256, token))
  end
end
