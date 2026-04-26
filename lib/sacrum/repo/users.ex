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

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.User

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.User

  @spec insert(map() | Ecto.Changeset.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Ecto.Changeset{} = changeset) do
    Repo.insert(changeset)
  end

  def insert(attrs) when is_map(attrs) do
    %User{}
    |> User.create_changeset(attrs)
    |> Repo.insert()
  end

  @spec update(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  @spec update_password(User.t(), map()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def update_password(%User{} = user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> Repo.update()
  end

  @spec delete(User.t()) :: {:ok, User.t()} | {:error, Ecto.Changeset.t()}
  def delete(%User{} = user), do: Repo.delete(user)
end
