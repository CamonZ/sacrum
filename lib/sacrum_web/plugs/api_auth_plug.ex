defmodule SacrumWeb.Plugs.ApiAuthPlug do
  @moduledoc """
  Plug for account API token or daemon reconnect credential authentication.

  Extracts Bearer token from Authorization header, verifies it,
  and assigns the owning account to the connection. A valid daemon reconnect
  credential resolves to the daemon's owning account.

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
  alias Sacrum.Repo.{Daemons, Users}

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
        unauthorized(conn, "Invalid daemon credentials")
    end
  end

  defp authenticate(conn, token) do
    case Auth.verify_token(token) do
      {:ok, user} ->
        Auth.update_token_last_used(token)

        {:ok,
         conn
         |> assign(:current_user, user)
         |> assign(:api_token, token)}

      {:error, reason} ->
        if daemon_identity_header?(conn) do
          authenticate_daemon(conn, token)
        else
          {:error, reason}
        end
    end
  end

  defp authenticate_daemon(conn, token) do
    case get_req_header(conn, "x-daemon-id") do
      [daemon_id | _] when byte_size(daemon_id) > 0 ->
        authenticate_daemon_credential(conn, token, String.trim(daemon_id))

      _ ->
        {:error, :invalid}
    end
  end

  defp authenticate_daemon_credential(conn, token, daemon_id) do
    case Daemons.authenticate_reconnect(daemon_id, token) do
      {:ok, daemon, _credential} -> authenticate_daemon_user(conn, token, daemon.user_id)
      {:error, :invalid_credentials} -> {:error, :invalid_daemon_credentials}
    end
  end

  defp authenticate_daemon_user(conn, token, user_id) do
    case Users.get(user_id) do
      {:ok, user} ->
        {:ok,
         conn
         |> assign(:current_user, user)
         |> assign(:api_token, token)}

      _ ->
        {:error, :invalid_daemon_credentials}
    end
  end

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

  defp unauthorized(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: message}))
    |> halt()
  end
end
