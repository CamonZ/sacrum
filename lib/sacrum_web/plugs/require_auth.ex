defmodule SacrumWeb.Plugs.RequireAuth do
  @moduledoc """
  Plug to require authentication. Redirects to /auth/google if no user is logged in.
  """

  import Plug.Conn

  @spec init(term()) :: term()
  def init(opts) do
    opts
  end

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if is_nil(conn.assigns[:current_user]) do
      conn
      |> Phoenix.Controller.put_flash(:error, "You must be logged in to access this page.")
      |> Phoenix.Controller.redirect(to: "/sign-in")
      |> halt()
    else
      conn
    end
  end
end
