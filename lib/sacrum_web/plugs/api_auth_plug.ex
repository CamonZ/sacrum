defmodule SacrumWeb.Plugs.ApiAuthPlug do
  @moduledoc """
  Plug for account API token or daemon access token authentication.

  Extracts Bearer token from Authorization header, verifies it,
  and assigns the owning account to the connection. A valid daemon access
  token resolves to the daemon's owning account.

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
  alias Sacrum.Repo.Daemons

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- extract_token(conn),
         {:ok, conn} <- authenticate(conn, token) do
      conn
    else
      {:error, :missing_token} ->
        unauthorized(conn, "Missing authorization header")

      {:error, :invalid_format} ->
        unauthorized(conn, "Invalid authorization header format")

      {:error, :invalid} ->
        unauthorized(conn, "Invalid API token")

      {:error, :expired} ->
        unauthorized(conn, "API token has expired")

      {:error, :invalid_daemon_credentials} ->
        unauthorized(conn, "Invalid daemon credentials", "invalid_credentials")

      {:error, :unavailable} ->
        conn
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "unavailable"}))
        |> halt()
    end
  end

  @daemon_token_prefix "sacd_"

  # Daemon access tokens are routed straight to the daemon lookup so a daemon
  # request costs one indexed SELECT. Everything else is an account API token.
  defp authenticate(conn, token) do
    if daemon_request?(conn, token) do
      authenticate_daemon(conn, token)
    else
      authenticate_account(conn, token)
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  defp authenticate_account(conn, token) do
    case Auth.verify_token(token) do
      {:ok, user} ->
        Auth.update_token_last_used(token)

        {:ok,
         conn
         |> assign(:current_user, user)
         |> assign(:api_token, token)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authenticate_daemon(conn, token) do
    with [daemon_id | _] <- get_req_header(conn, "x-daemon-id"),
         {:ok, %{daemon: daemon, credential: credential, user: user}} <-
           Daemons.authenticate_access(String.trim(daemon_id), token) do
      {:ok,
       conn
       |> assign(:daemon_principal, %{daemon_id: daemon.id, credential_id: credential.id})
       |> assign(:current_user, user)
       |> assign(:api_token, token)}
    else
      {:error, :unavailable} -> {:error, :unavailable}
      _ -> {:error, :invalid_daemon_credentials}
    end
  end

  defp daemon_request?(conn, token),
    do: String.starts_with?(token, @daemon_token_prefix) and daemon_identity_header?(conn)

  defp daemon_identity_header?(conn), do: get_req_header(conn, "x-daemon-id") != []

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

  defp unauthorized(conn, message, code \\ nil) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(if(code, do: %{error: message, code: code}, else: %{error: message}))
    )
    |> halt()
  end
end
