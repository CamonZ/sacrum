defmodule Sacrum.Repo.Users do
  @moduledoc """
  Basic CRUD operations for users.
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
