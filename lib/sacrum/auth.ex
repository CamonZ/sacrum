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
  @spec create_api_token(User.t(), map()) ::
          {:ok, String.t(), ApiToken.t()} | {:error, Ecto.Changeset.t()}
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

  # Authentication runs on every request; recording use does not need to.
  @last_used_interval_seconds 300

  @doc "Seconds a token's `last_used_at` may lag behind its most recent use."
  @spec last_used_interval_seconds() :: pos_integer()
  def last_used_interval_seconds, do: @last_used_interval_seconds

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
  @spec verify_token(String.t()) :: {:ok, User.t()} | {:error, :invalid | :expired}
  def verify_token(plaintext_token) do
    with {:ok, token} <- verify_api_token(plaintext_token), do: {:ok, token.user}
  end

  @doc """
  Verifies a token and returns it with its user preloaded, in one query.
  Expiry is checked on every call.
  """
  @spec verify_api_token(String.t()) :: {:ok, ApiToken.t()} | {:error, :invalid | :expired}
  def verify_api_token(plaintext_token) when is_binary(plaintext_token) do
    token_hash = hash_token(plaintext_token)

    query =
      from t in ApiToken,
        join: u in assoc(t, :user),
        where: t.token_hash == ^token_hash,
        preload: [user: u]

    case Repo.one(query) do
      nil ->
        {:error, :invalid}

      %ApiToken{expires_at: expires_at} = token when not is_nil(expires_at) ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:ok, token}
        else
          {:error, :expired}
        end

      %ApiToken{} = token ->
        {:ok, token}
    end
  end

  def verify_api_token(_), do: {:error, :invalid}

  @doc """
  Records a verified token's use. `last_used_at` is written at most once per
  #{@last_used_interval_seconds}-second interval: a token used within the
  interval skips the write, and the conditional update keeps concurrent
  requests from writing the same interval twice.
  """
  @spec touch_token_last_used(ApiToken.t(), DateTime.t()) :: :ok
  def touch_token_last_used(%ApiToken{} = token, now \\ DateTime.utc_now()) do
    threshold = DateTime.add(now, -@last_used_interval_seconds, :second)

    if is_nil(token.last_used_at) or DateTime.compare(token.last_used_at, threshold) != :gt do
      Repo.update_all(
        from(t in ApiToken,
          where: t.id == ^token.id and (is_nil(t.last_used_at) or t.last_used_at <= ^threshold)
        ),
        set: [last_used_at: now]
      )
    end

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
