defmodule SacrumWeb.AuthController do
  use SacrumWeb, :controller

  alias Sacrum.Accounts.Auth

  require Logger

  @doc """
  Redirect to Google's OAuth consent screen.
  """
  @spec request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request(conn, _params) do
    config = Application.get_env(:sacrum, :google_oauth)

    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    conn = put_session(conn, :oauth_state, state)

    url =
      "https://accounts.google.com/o/oauth2/v2/auth?" <>
        URI.encode_query(%{
          client_id: config[:client_id],
          redirect_uri: config[:redirect_uri],
          response_type: "code",
          scope: "openid email profile",
          state: state
        })

    redirect(conn, external: url)
  end

  @doc """
  Handle the OAuth callback from Google.
  """
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, params) do
    config = Application.get_env(:sacrum, :google_oauth)
    stored_state = get_session(conn, :oauth_state)
    callback_state = params["state"]

    if stored_state != callback_state do
      handle_state_mismatch(conn, stored_state, callback_state)
    else
      handle_token_exchange(conn, params, config)
    end
  end

  defp handle_state_mismatch(conn, stored_state, callback_state) do
    Logger.warning("OAuth state mismatch: expected #{stored_state}, got #{callback_state}")

    conn
    |> put_flash(:error, "Invalid OAuth state parameter")
    |> redirect(to: "/auth-error")
  end

  defp handle_token_exchange(conn, params, config) do
    case exchange_code_for_token(params["code"], config) do
      {:ok, tokens} ->
        handle_token_verification(conn, tokens, config)

      {:error, reason} ->
        Logger.error("Token exchange failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "OAuth authentication failed")
        |> redirect(to: "/auth-error")
    end
  end

  defp handle_token_verification(conn, tokens, config) do
    case verify_id_token(tokens["id_token"], config) do
      {:ok, claims} ->
        handle_user_signin(conn, claims)

      {:error, reason} ->
        Logger.warning("ID token verification failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Invalid ID token")
        |> redirect(to: "/auth-error")
    end
  end

  @doc """
  Sign out the current user.
  """
  @spec signout(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def signout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "You have been signed out.")
    |> redirect(to: "/")
  end

  defp exchange_code_for_token(code, config) do
    body = %{
      code: code,
      client_id: config[:client_id],
      client_secret: config[:client_secret],
      redirect_uri: config[:redirect_uri],
      grant_type: "authorization_code"
    }

    case Req.post("https://oauth2.googleapis.com/token", form: body) do
      {:ok, response} ->
        {:ok, response.body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp verify_id_token(id_token, config) do
    # FIXME: signature is not verified against Google's JWKS — claims-only check.
    # Migrate to Assent.Strategy.Google before exposing publicly.
    case decode_jwt_unverified(id_token) do
      {:ok, claims} ->
        if claims["aud"] == config[:client_id] &&
             claims["iss"] == "https://accounts.google.com" &&
             claims["email_verified"] == true &&
             is_integer(claims["exp"]) &&
             claims["exp"] > System.os_time(:second) do
          {:ok, claims}
        else
          {:error, :invalid_claims}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_jwt_unverified(token) do
    parts = String.split(token, ".")

    with [_header, payload, _signature] <- parts,
         {:ok, decoded} <- Base.url_decode64(payload, padding: false),
         {:ok, claims} <- Jason.decode(decoded) do
      {:ok, claims}
    else
      _error -> {:error, :invalid_token}
    end
  end

  defp handle_user_signin(conn, claims) do
    attrs = %{
      google_sub: claims["sub"],
      email: claims["email"],
      name: claims["name"],
      avatar_url: claims["picture"]
    }

    case Auth.find_or_invite_user(attrs) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> configure_session(max_age: 30 * 24 * 60 * 60)
        |> redirect(to: "/dashboard")

      {:error, :not_invited} ->
        redirect(conn, to: "/not-invited")

      {:error, reason} ->
        Logger.error("Sign-in failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Sign-in failed. Please try again.")
        |> redirect(to: "/auth-error")
    end
  end
end
