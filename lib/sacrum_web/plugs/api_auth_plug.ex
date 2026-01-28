defmodule SacrumWeb.Plugs.ApiAuthPlug do
  @moduledoc """
  Plug for API token authentication.

  Extracts Bearer token from Authorization header, verifies it,
  and assigns the current_user to the connection.

  ## Usage

  Add to your router pipeline:

      pipeline :api_authenticated do
        plug SacrumWeb.Plugs.ApiAuthPlug
      end

  Or use in a specific controller:

      plug SacrumWeb.Plugs.ApiAuthPlug when action in [:create, :update, :delete]
  """

  import Plug.Conn
  alias Sacrum.Auth

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, user} <- Auth.verify_token(token) do
      Auth.update_token_last_used(token)

      conn
      |> assign(:current_user, user)
      |> assign(:api_token, token)
    else
      {:error, :missing_token} ->
        unauthorized(conn, "Missing authorization header")

      {:error, :invalid_format} ->
        unauthorized(conn, "Invalid authorization header format")

      {:error, :invalid} ->
        unauthorized(conn, "Invalid API token")

      {:error, :expired} ->
        unauthorized(conn, "API token has expired")
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:error, :missing_token}

      [auth_header | _] ->
        case String.split(auth_header, " ", parts: 2) do
          ["Bearer", token] when byte_size(token) > 0 ->
            {:ok, String.trim(token)}

          _ ->
            {:error, :invalid_format}
        end
    end
  end

  defp unauthorized(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: message}))
    |> halt()
  end
end
