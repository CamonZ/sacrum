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

    {:ok, daemon, bootstrap} = Sacrum.Accounts.Daemons.create(user.id)

    {:ok, daemon, token, _credential} =
      Sacrum.Accounts.Daemons.exchange_bootstrap(daemon.id, bootstrap)

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
    assert is_binary(channel.assigns.credential_id)

    assert [{_pid, %{user_id: user_id, credential_id: credential_id}}] =
             Sacrum.DaemonConnectionRegistry.lookup(daemon.id)

    assert user_id == daemon.user_id
    assert credential_id == channel.assigns.credential_id

    ref = Process.monitor(channel.channel_pid)
    leave(channel)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
  end

  test "committed revoke terminates the connected standalone session" do
    {user, daemon, token, _} = setup_daemon("revoke_live")

    {:ok, socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{daemon.id}")
    monitor = Process.monitor(channel.channel_pid)

    assert {:ok, revoked} = Sacrum.Accounts.Daemons.revoke(user.id, daemon.id)
    assert revoked.status == "revoked"

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []

    assert :error =
             connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})
  end

  test "rotation terminates only affected sessions; siblings survive and exchange reconnects" do
    {user, daemon, token, _} = setup_daemon("rotate_live")

    {:ok, sibling, sibling_bootstrap} = Sacrum.Accounts.Daemons.create(user.id)

    {:ok, _, sibling_token, _} =
      Sacrum.Accounts.Daemons.exchange_bootstrap(sibling.id, sibling_bootstrap)

    {:ok, socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{daemon.id}")
    monitor = Process.monitor(channel.channel_pid)

    {:ok, sibling_socket} =
      connect(UserSocket, %{"daemon_id" => sibling.id, "reconnect_token" => sibling_token})

    {:ok, _, sibling_channel} = subscribe_and_join(sibling_socket, "daemon:#{sibling.id}")
    sibling_monitor = Process.monitor(sibling_channel.channel_pid)

    assert {:ok, _, new_bootstrap, _} =
             Sacrum.Accounts.Daemons.rotate_bootstrap(user.id, daemon.id)

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []

    # The sibling daemon session is unaffected by this daemon's rotation.
    ref = Phoenix.ChannelTest.push(sibling_channel, "report", %{})
    assert_reply ref, :error, %{reason: "unsupported_operation"}
    refute_received {:DOWN, ^sibling_monitor, :process, _, _}

    # A fresh exchange reconnects on the same daemon identity.
    {:ok, _, fresh_reconnect, _} =
      Sacrum.Accounts.Daemons.exchange_bootstrap(daemon.id, new_bootstrap)

    {:ok, fresh_socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => fresh_reconnect})

    assert {:ok, _, fresh_channel} = subscribe_and_join(fresh_socket, "daemon:#{daemon.id}")
    assert fresh_channel.assigns.daemon_id == daemon.id
    leave(sibling_channel)
  end

  test "delayed invalidation cannot terminate a newer valid session" do
    {user, daemon, token, _} = setup_daemon("stale_invalidation")

    {:ok, socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{daemon.id}")
    monitor = Process.monitor(channel.channel_pid)

    assert {:ok, _, new_bootstrap, _} =
             Sacrum.Accounts.Daemons.rotate_bootstrap(user.id, daemon.id)

    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}

    {:ok, _, fresh_reconnect, _} =
      Sacrum.Accounts.Daemons.exchange_bootstrap(daemon.id, new_bootstrap)

    {:ok, fresh_socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => fresh_reconnect})

    {:ok, _, fresh_channel} = subscribe_and_join(fresh_socket, "daemon:#{daemon.id}")
    fresh_monitor = Process.monitor(fresh_channel.channel_pid)

    # A delayed duplicate invalidation arrives after the newer session joined.
    send(fresh_channel.channel_pid, :daemon_credentials_invalidated)

    ref = Phoenix.ChannelTest.push(fresh_channel, "report", %{})
    assert_reply ref, :error, %{reason: "unsupported_operation"}
    refute_received {:DOWN, ^fresh_monitor, :process, _, _}
  end

  test "legacy user-authenticated session is terminated by revoke" do
    {user, daemon, token, socket} = setup_daemon("legacy_revoke")

    {:ok, _, channel} =
      subscribe_and_join(socket, "daemon:#{daemon.id}", %{"enrollment_token" => token})

    assert [{_pid, %{user_id: user_id}}] = Sacrum.DaemonConnectionRegistry.lookup(daemon.id)
    assert user_id == user.id

    monitor = Process.monitor(channel.channel_pid)
    assert {:ok, _} = Sacrum.Accounts.Daemons.revoke(user.id, daemon.id)
    assert_receive {:DOWN, ^monitor, :process, _pid, _reason}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
  end

  test "failed mutation emits no invalidation and unrelated sessions survive" do
    {user, daemon, token, _} = setup_daemon("failed_rotate")

    {:ok, socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{daemon.id}")

    {:ok, terminal, _} = Sacrum.Accounts.Daemons.create(user.id)
    assert {:ok, _} = Sacrum.Accounts.Daemons.revoke(user.id, terminal.id)

    assert {:error, :invalid_credentials} =
             Sacrum.Accounts.Daemons.rotate_bootstrap(user.id, terminal.id)

    ref = Phoenix.ChannelTest.push(channel, "report", %{})
    assert_reply ref, :error, %{reason: "unsupported_operation"}
    assert [{_pid, %{credential_id: _}}] = Sacrum.DaemonConnectionRegistry.lookup(daemon.id)
  end

  test "rejects a credential belonging to another daemon" do
    {_user, daemon, _token, socket} = setup_daemon("first")
    {_other_user, _other_daemon, other_token, _other_socket} = setup_daemon("second")

    assert {:error, %{reason: "invalid_credentials"}} =
             subscribe_and_join(socket, "daemon:#{daemon.id}", %{
               "enrollment_token" => other_token
             })
  end

  test "standalone session owns registration and duplicate failure cannot release it" do
    {user, daemon, token, _} = setup_daemon("standalone")

    assert {:ok, socket} =
             connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    assert {:ok, _, channel} =
             subscribe_and_join(socket, "daemon:#{daemon.id}", %{
               "user_id" => Ecto.UUID.generate()
             })

    assert channel.assigns.user_id == user.id
    refute Map.has_key?(channel.assigns, :current_user)
    owner = channel.channel_pid
    assert [{^owner, _}] = Sacrum.DaemonConnectionRegistry.lookup(daemon.id)

    assert {:ok, duplicate} =
             connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    assert {:error, %{reason: "already_connected"}} =
             subscribe_and_join(duplicate, "daemon:#{daemon.id}")

    assert [{^owner, _}] = Sacrum.DaemonConnectionRegistry.lookup(daemon.id)
    :ok = Sacrum.DaemonConnectionRegistry.unregister(daemon.id)
    assert [{^owner, _}] = Sacrum.DaemonConnectionRegistry.lookup(daemon.id)
    monitor = Process.monitor(owner)
    leave(channel)
    assert_receive {:DOWN, ^monitor, :process, ^owner, _}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
    assert {:ok, _, rejoined} = subscribe_and_join(duplicate, "daemon:#{daemon.id}")
    assert rejoined.assigns.daemon_id == daemon.id
  end

  test "standalone topic identity is exact and project channels remain forbidden" do
    {_user, daemon, token, _} = setup_daemon("topics")
    {:ok, socket} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})

    assert {:error, %{reason: "identity_mismatch"}} =
             subscribe_and_join(socket, "daemon:#{Ecto.UUID.generate()}")

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, "project:#{Ecto.UUID.generate()}")

    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
  end

  test "join rechecks revocation and rotation since socket authentication" do
    for action <- [:rotate, :revoke] do
      {user, daemon, token, _} = setup_daemon("recheck#{action}")
      {:ok, socket} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})
      apply(Sacrum.Accounts.Daemons, action, [user.id, daemon.id])

      assert {:error, %{reason: "invalid_credentials"}} =
               subscribe_and_join(socket, "daemon:#{daemon.id}")

      assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
    end
  end

  test "reconnect survives bootstrap expiry and channel process restart" do
    {_user, daemon, token, _} = setup_daemon("restart")
    import Ecto.Query

    Repo.update_all(
      from(c in Sacrum.Repo.Schemas.DaemonCredential,
        where: c.daemon_id == ^daemon.id and c.credential_kind == "bootstrap"
      ),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60)]
    )

    {:ok, socket} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})
    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{daemon.id}")
    monitor = Process.monitor(channel.channel_pid)
    close(channel)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
    {:ok, fresh} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})
    assert {:ok, _, restarted} = subscribe_and_join(fresh, "daemon:#{daemon.id}")
    assert restarted.assigns.daemon_id == daemon.id
  end

  test "join refuses reconnect that expired after socket authentication" do
    {_user, daemon, token, _} = setup_daemon("expiry")
    {:ok, socket} = connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => token})
    import Ecto.Query

    Repo.update_all(
      from(c in Sacrum.Repo.Schemas.DaemonCredential,
        where: c.id == ^socket.assigns.principal.credential_id
      ),
      set: [expires_at: DateTime.utc_now()]
    )

    assert {:error, %{reason: "invalid_credentials"}} =
             subscribe_and_join(socket, "daemon:#{daemon.id}")

    assert Sacrum.DaemonConnectionRegistry.lookup(daemon.id) == []
  end
end
