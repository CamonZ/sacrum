defmodule Sacrum.Repo.Users do
  @moduledoc """
  Basic CRUD operations for users.

  ## Error Contract

  - `get/1` returns `{:ok, user}` or `{:error, :not_found}`
  - `insert/1` returns `{:ok, user}` or `{:error, changeset}`
  - `update/2` returns `{:ok, user}` or `{:error, changeset}`
  - `update_password/2` returns `{:ok, user}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, user}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.User

  def get(id) do
    case Repo.get(User, id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  def insert(attrs) do
    %User{}
    |> User.create_changeset(attrs)
    |> Repo.insert()
  end

  def update(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  def update_password(%User{} = user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> Repo.update()
  end

  def delete(%User{} = user), do: Repo.delete(user)
end
