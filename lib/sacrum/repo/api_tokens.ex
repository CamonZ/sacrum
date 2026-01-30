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

  def for_user(user_id) do
    from(t in ApiToken, where: t.user_id == ^user_id)
  end
end
