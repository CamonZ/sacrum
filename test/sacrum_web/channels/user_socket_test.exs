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
end
