defmodule SacrumWeb.DaemonExchangeController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Daemons
  alias SacrumWeb.DaemonEndpoints

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, _params) do
    conn = put_resp_header(conn, "cache-control", "no-store")

    with :ok <- validate_body(conn),
         {:ok, endpoint} <- DaemonEndpoints.base_url(),
         {:ok, daemon, token, credential} <-
           Daemons.exchange_bootstrap(
             conn.body_params["daemon_id"],
             conn.body_params["bootstrap_token"]
           ) do
      json(conn, %{
        daemon_id: daemon.id,
        reconnect_token: token,
        expires_at: credential.expires_at,
        server_endpoint: endpoint,
        socket_endpoint: DaemonEndpoints.socket_url(endpoint)
      })
    else
      {:error, :invalid_request} -> error(conn, 400, "invalid_request")
      {:error, :invalid_credentials} -> error(conn, 401, "invalid_credentials")
      {:error, _reason} -> error(conn, 503, "exchange_unavailable")
    end
  end

  defp validate_body(%{
         body_params: %{"daemon_id" => id, "bootstrap_token" => token} = body,
         query_params: query
       })
       when is_binary(id) and is_binary(token) do
    if map_size(body) == 2 and map_size(query) == 0 and byte_size(id) <= 36 and
         byte_size(token) in 1..512, do: :ok, else: {:error, :invalid_request}
  end

  defp validate_body(_), do: {:error, :invalid_request}

  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: code})
end
