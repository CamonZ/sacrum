defmodule Sacrum.Accounts.Auth do
  @moduledoc """
  Authentication and authorization logic.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.User

  @doc """
  Find a user by Google sub or create one if invited.

  Returns:
    - `{:ok, user}` if user exists with that google_sub
    - `{:ok, user}` if user invited and created new user
    - `{:error, :not_invited}` if email not in invites
    - `{:error, reason}` if creation fails
  """
  @spec find_or_invite_user(map()) :: {:ok, User.t()} | {:error, atom() | Ecto.Changeset.t()}
  def find_or_invite_user(%{
        google_sub: google_sub,
        email: email,
        name: name,
        avatar_url: avatar_url
      }) do
    case Repo.Users.get_by(conditions: [google_sub: google_sub]) do
      {:ok, user} ->
        {:ok, user}

      {:error, :not_found} ->
        case Repo.Invites.get_by(conditions: [email: email]) do
          {:ok, _invite} ->
            attrs = %{
              email: email,
              name: name,
              google_sub: google_sub,
              avatar_url: avatar_url
            }

            %User{}
            |> User.oauth_changeset(attrs)
            |> Repo.Users.insert()

          {:error, :not_found} ->
            {:error, :not_invited}
        end
    end
  end
end
