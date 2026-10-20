defmodule SacrumWeb.Graphql.ContextPlug do
  @moduledoc """
  Plug to extract the authenticated user and API token from connection assigns
  and place them in the Absinthe context.
  """

  import Plug.Conn

  @spec init(keyword()) :: keyword()
  def init(opts) do
    opts
  end

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    context = %{
      current_user: conn.assigns[:current_user],
      daemon_principal: conn.assigns[:daemon_principal],
      api_token: conn.assigns[:api_token]
    }

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_private(:absinthe, %{context: context})
  end
end
