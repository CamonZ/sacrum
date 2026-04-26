defmodule SacrumWeb.Plugs.FetchCurrentUser do
  @moduledoc """
  Plug to fetch the current_user from session and assign it to conn.
  """

  import Plug.Conn

  alias Sacrum.Repo

  @spec init(term()) :: term()
  def init(opts) do
    opts
  end

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)

    if user_id do
      case Repo.Users.get(user_id) do
        {:ok, user} ->
          assign(conn, :current_user, user)

        {:error, _} ->
          assign(conn, :current_user, nil)
      end
    else
      assign(conn, :current_user, nil)
    end
  end
end
