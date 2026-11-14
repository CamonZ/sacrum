defmodule SacrumWeb.DaemonExchangeController do
  @moduledoc """
  Unauthenticated daemon token endpoints.

    * `POST /api/daemon/exchange` - consumes a one-time registration token.
    * `POST /api/daemon/refresh` - rotates a refresh token.

  Both return a fresh access/refresh pair. Refresh is a separate endpoint
  because the access token it replaces may already have expired.
  """

  use SacrumWeb, :controller

  alias Sacrum.Accounts.Daemons

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    respond(conn, "bootstrap_token", &Daemons.exchange_bootstrap/2)
  end

  @spec refresh(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def refresh(conn, _params) do
    respond(conn, "refresh_token", &Daemons.refresh/2)
  end

  defp respond(conn, token_key, fun) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with :ok <- validate_body(conn, token_key),
         {:ok, daemon, pair} <-
           fun.(conn.body_params["daemon_id"], conn.body_params[token_key]) do
      json(conn, %{
        daemon_id: daemon.id,
        access_token: pair.access_token,
        access_token_expires_at: pair.access_expires_at,
        refresh_token: pair.refresh_token,
        refresh_token_expires_at: pair.refresh_expires_at
      })
    else
      {:error, :invalid_request} -> error(conn, 400, "invalid_request")
      {:error, :invalid_credentials} -> error(conn, 401, "invalid_credentials")
      {:error, _reason} -> error(conn, 503, "unavailable")
    end
  end

  defp validate_body(
         %{body_params: %{"daemon_id" => id} = body, query_params: query},
         token_key
       )
       when is_binary(id) do
    token = Map.get(body, token_key)

    if is_binary(token) and map_size(body) == 2 and map_size(query) == 0 and
         byte_size(id) <= 36 and byte_size(token) in 1..512,
       do: :ok,
       else: {:error, :invalid_request}
  end

  defp validate_body(_, _), do: {:error, :invalid_request}

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
