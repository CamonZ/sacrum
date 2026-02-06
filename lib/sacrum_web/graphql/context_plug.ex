defmodule SacrumWeb.Graphql.ContextPlug do
  @moduledoc """
  Plug to extract current user and API token from connection assigns
  and place them in the Absinthe context.
  """

  import Plug.Conn

  def init(opts) do
    opts
  end

  def call(conn, _opts) do
    context = %{
      current_user: conn.assigns[:current_user],
      api_token: conn.assigns[:api_token]
    }

    put_private(conn, :absinthe, %{context: context})
  end
end
