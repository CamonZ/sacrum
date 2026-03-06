defmodule Sacrum.Repo.ApiTokens do
  @moduledoc """
  Basic CRUD operations for API tokens.

  ## Error Contract

  - `get/1` returns `{:ok, token}` or `{:error, :not_found}`
  - `insert/1` returns `{:ok, token}` or `{:error, changeset}`
  - `update/2` returns `{:ok, token}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, token}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ApiToken

  @spec get(String.t()) :: {:ok, ApiToken.t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(ApiToken, id) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  @spec insert(map()) :: {:ok, ApiToken.t()} | {:error, Ecto.Changeset.t()}
  def insert(attrs) do
    %ApiToken{}
    |> ApiToken.changeset(attrs)
    |> Repo.insert()
  end

  @spec update(ApiToken.t(), map()) :: {:ok, ApiToken.t()} | {:error, Ecto.Changeset.t()}
  def update(%ApiToken{} = token, attrs) do
    token
    |> ApiToken.changeset(attrs)
    |> Repo.update()
  end

  @spec delete(ApiToken.t()) :: {:ok, ApiToken.t()} | {:error, Ecto.Changeset.t()}
  def delete(%ApiToken{} = token), do: Repo.delete(token)

  @spec for_user(String.t()) :: Ecto.Query.t()
  def for_user(user_id) do
    from(t in ApiToken, where: t.user_id == ^user_id)
  end
end
