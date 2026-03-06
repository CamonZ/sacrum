defmodule SacrumWeb.Graphql.ContextPlug do
  @moduledoc """
  Plug to extract current user and API token from connection assigns
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
      api_token: conn.assigns[:api_token]
    }

    put_private(conn, :absinthe, %{context: context})
  end
end
