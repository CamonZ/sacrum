defmodule SacrumWeb.UserSocketTest do
  use Sacrum.DataCase, async: true

  alias SacrumWeb.UserSocket
  alias Sacrum.Auth
  alias Sacrum.Repo.Users

  @valid_user_attrs %{
    email: "socket@example.com",
    username: "socketuser",
    password: "password123"
  }

  defp create_user_and_token do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, token, _api_token} = Auth.create_api_token(user, %{name: "test token"})
    {user, token}
  end

  describe "connect/3" do
    test "connects successfully with valid API token" do
      {user, token} = create_user_and_token()

      assert {:ok, socket} = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
      assert socket.assigns.current_user.id == user.id
    end

    test "rejects connection with invalid token" do
      assert :error = UserSocket.connect(%{"token" => "sac_invalid"}, %Phoenix.Socket{}, %{})
    end

    test "rejects connection with missing token" do
      assert :error = UserSocket.connect(%{}, %Phoenix.Socket{}, %{})
    end
  end

  describe "id/1" do
    test "returns user-scoped socket id" do
      {user, token} = create_user_and_token()
      {:ok, socket} = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})

      assert UserSocket.id(socket) == "user_socket:#{user.id}"
    end
  end

  test "standalone principal derives owner and credential from verified reconnect" do
    {user, _} = create_user_and_token()
    {:ok, daemon, bootstrap} = Sacrum.Accounts.Daemons.create(user.id)
    {:ok, _, token, credential} = Sacrum.Accounts.Daemons.exchange_bootstrap(daemon.id, bootstrap)

    params = %{
      "daemon_id" => daemon.id,
      "reconnect_token" => token,
      "user_id" => Ecto.UUID.generate(),
      "credential_id" => Ecto.UUID.generate()
    }

    assert {:ok, socket} = UserSocket.connect(params, %Phoenix.Socket{}, %{})

    assert socket.assigns.principal == %{
             type: :daemon,
             daemon_id: daemon.id,
             user_id: user.id,
             credential_id: credential.id
           }

    refute Map.has_key?(socket.assigns, :current_user)
    refute inspect(socket.assigns) =~ token
    assert UserSocket.id(socket) == "daemon_socket:#{daemon.id}:#{credential.id}"
  end

  test "bootstrap, wrong identity, revoked reconnect and mixed principals fail closed" do
    {user, account_token} = create_user_and_token()
    {:ok, daemon, bootstrap} = Sacrum.Accounts.Daemons.create(user.id)

    assert :error =
             UserSocket.connect(
               %{"daemon_id" => daemon.id, "reconnect_token" => bootstrap},
               %Phoenix.Socket{},
               %{}
             )

    {:ok, _, token, _} = Sacrum.Accounts.Daemons.exchange_bootstrap(daemon.id, bootstrap)

    for params <- [
          %{"daemon_id" => Ecto.UUID.generate(), "reconnect_token" => token},
          %{"daemon_id" => "malformed", "reconnect_token" => token},
          %{"daemon_id" => daemon.id, "reconnect_token" => bootstrap},
          %{"daemon_id" => daemon.id, "reconnect_token" => token, "token" => account_token},
          %{"daemon_id" => daemon.id, "reconnect_token" => %{}}
        ] do
      assert :error = UserSocket.connect(params, %Phoenix.Socket{}, %{})
    end

    {:ok, _, _} = Sacrum.Accounts.Daemons.rotate(user.id, daemon.id)

    assert :error =
             UserSocket.connect(
               %{"daemon_id" => daemon.id, "reconnect_token" => token},
               %Phoenix.Socket{},
               %{}
             )
  end
end
