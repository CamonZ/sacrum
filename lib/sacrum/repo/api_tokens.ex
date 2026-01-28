defmodule Sacrum.Repo.ApiTokens do
  @moduledoc """
  Basic CRUD operations for API tokens.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ApiToken

  def get(id) do
    case Repo.get(ApiToken, id) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  def get!(id), do: Repo.get!(ApiToken, id)

  def get_by(clauses) do
    case Repo.get_by(ApiToken, clauses) do
      nil -> {:error, :not_found}
      token -> {:ok, token}
    end
  end

  def list, do: Repo.all(ApiToken)

  def list(query), do: Repo.all(query)

  def insert(attrs) do
    %ApiToken{}
    |> ApiToken.changeset(attrs)
    |> Repo.insert()
  end

  def update(%ApiToken{} = token, attrs) do
    token
    |> ApiToken.changeset(attrs)
    |> Repo.update()
  end

  def delete(%ApiToken{} = token), do: Repo.delete(token)

  def query, do: from(t in ApiToken)

  def for_user(user_id) do
    from(t in ApiToken, where: t.user_id == ^user_id)
  end
end
