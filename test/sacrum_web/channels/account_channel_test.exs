defmodule SacrumWeb.AccountChannelTest do
  use Sacrum.DataCase, async: false

  import Phoenix.ChannelTest

  alias Sacrum.Accounts.Daemons
  alias Sacrum.Auth
  alias Sacrum.Repo.Users
  alias Sacrum.Realtime.AccountChannelCdcContract
  alias SacrumWeb.AccountChannel
  alias SacrumWeb.UserSocket

  @endpoint SacrumWeb.Endpoint

  setup do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp create_user(suffix) do
    {:ok, user} =
      Users.insert(%{
        email: "account-channel-#{suffix}@example.com",
        username: "account_channel_#{suffix}",
        password: "password123"
      })

    user
  end

  defp connect_user(user) do
    {:ok, token, _api_token} = Auth.create_api_token(user, %{name: "account channel test"})
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    socket
  end

  test "owner can join the account topic and active clients receive fleet events" do
    user = create_user("owner")
    socket = connect_user(user)
    sibling_socket = connect_user(user)

    assert {:ok, _reply, channel} = subscribe_and_join(socket, "account:#{user.id}")

    assert {:ok, _reply, sibling_channel} =
             subscribe_and_join(sibling_socket, "account:#{user.id}")

    assert channel.assigns.account_id == user.id
    assert sibling_channel.assigns.account_id == user.id

    {:ok, daemon, _bootstrap} = Daemons.create(user.id, %{name: "Fleet bot"})
    assert :ok = AccountChannel.broadcast_daemon_created(user.id, daemon)

    assert_push "daemon_created", created_payload
    assert_push "daemon_created", sibling_payload
    assert created_payload == sibling_payload
    assert created_payload.id == daemon.id
    assert created_payload.status == "pending"
    assert created_payload.name == "Fleet bot"
    assert created_payload.display_name == "Fleet bot"
    assert created_payload.max_concurrency == nil
    assert created_payload.schema_version == 1

    leave(channel)
    leave(sibling_channel)
  end

  test "account topic authorization is owner scoped" do
    owner = create_user("authorized")
    other = create_user("foreign")
    socket = connect_user(owner)

    assert {:ok, _reply, _channel} = subscribe_and_join(socket, "account:#{owner.id}")

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(connect_user(owner), "account:#{other.id}")

    assert {:error, %{reason: "forbidden"}} = subscribe_and_join(socket, "account:not-a-user")
  end

  test "standalone daemon principals cannot join account topics" do
    user = create_user("daemon")
    {:ok, daemon, bootstrap} = Daemons.create(user.id)

    {:ok, _daemon, reconnect_token, _credential} =
      Daemons.exchange_bootstrap(daemon.id, bootstrap)

    {:ok, socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => reconnect_token})

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, "account:#{user.id}")
  end

  test "account broadcasts use an explicit sanitized payload allowlist" do
    user = create_user("sanitized")
    {:ok, _reply, channel} = subscribe_and_join(connect_user(user), "account:#{user.id}")
    {:ok, daemon, _bootstrap} = Daemons.create(user.id, %{name: "Safe bot"})

    drain_created_event()

    daemon = Map.put(daemon, :token_hash, "must-not-be-broadcast")
    assert :ok = AccountChannel.broadcast_daemon_updated(user.id, daemon)
    assert_push "daemon_updated", payload

    assert Map.keys(payload) |> Enum.sort() == [
             :display_name,
             :enrolled_at,
             :id,
             :inserted_at,
             :max_concurrency,
             :name,
             :schema_version,
             :status,
             :updated_at
           ]

    refute Map.has_key?(payload, :token_hash)
    refute inspect(payload) =~ "must-not-be-broadcast"
    leave(channel)
  end

  test "channel-level delivery sanitizes raw daemon payloads" do
    user = create_user("raw")
    {:ok, _reply, channel} = subscribe_and_join(connect_user(user), "account:#{user.id}")

    raw_payload = %{
      id: Ecto.UUID.generate(),
      status: "pending",
      name: "Safe bot",
      token_hash: "must-not-be-delivered"
    }

    assert :ok =
             SacrumWeb.Endpoint.broadcast(
               AccountChannelCdcContract.topic(user.id),
               "daemon_updated",
               raw_payload
             )

    assert_push "daemon_updated", payload
    assert payload.id == raw_payload.id
    assert payload.display_name == "Safe bot"
    refute Map.has_key?(payload, :token_hash)
    refute inspect(payload) =~ "must-not-be-delivered"
    leave(channel)
  end

  defp drain_created_event do
    receive do
      %Phoenix.Socket.Broadcast{event: "daemon_created"} -> drain_created_event()
    after
      0 -> :ok
    end
  end
end
