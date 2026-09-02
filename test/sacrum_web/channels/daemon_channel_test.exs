defmodule SacrumWeb.DaemonChannelTest do
  use Sacrum.DataCase, async: false

  import Phoenix.ChannelTest

  alias Sacrum.Auth
  alias Sacrum.Repo.Users
  alias SacrumWeb.UserSocket

  @endpoint SacrumWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp setup_daemon(suffix \\ "channel") do
    {:ok, user} =
      Users.insert(%{
        email: "daemon-#{suffix}@example.com",
        username: "daemon#{suffix}",
        password: "password123"
      })

    {:ok, daemon, token} = Sacrum.Accounts.Daemons.create(user.id)
    {:ok, socket} = connect(UserSocket, %{"token" => api_token(user)})
    {user, daemon, token, socket}
  end

  defp api_token(user) do
    {:ok, token, _api_token} = Auth.create_api_token(user, %{name: "daemon channel test"})
    token
  end

  test "registers a valid daemon and cleans up on disconnect" do
    {_user, daemon, token, socket} = setup_daemon()

    assert {:ok, _reply, channel} =
             subscribe_and_join(socket, "daemon:#{daemon.id}", %{"enrollment_token" => token})

    assert channel.assigns.daemon_id == daemon.id
    assert channel.assigns.user_id == daemon.user_id
    assert [{_pid, user_id}] = Sacrum.DaemonConnectionRegistry.lookup(daemon.id)
    assert user_id == daemon.user_id

    ref = Process.monitor(channel.channel_pid)
    leave(channel)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
  end

  test "rejects a credential belonging to another daemon" do
    {_user, daemon, _token, socket} = setup_daemon("first")
    {_other_user, _other_daemon, other_token, _other_socket} = setup_daemon("second")

    assert {:error, %{reason: "invalid_credentials"}} =
             subscribe_and_join(socket, "daemon:#{daemon.id}", %{
               "enrollment_token" => other_token
             })
  end
end
