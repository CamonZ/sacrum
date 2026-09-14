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

  test "authenticated users join accounts:me and receive their internal account events" do
    user = create_user("owner")
    other = create_user("join_parameter")
    socket = connect_user(user)
    sibling_socket = connect_user(user)

    assert {:ok, _reply, channel} =
             subscribe_and_join(socket, "accounts:me", %{"user_id" => other.id})

    assert {:ok, _reply, sibling_channel} =
             subscribe_and_join(sibling_socket, "accounts:me")

    assert channel.assigns.account_id == user.id
    assert channel.assigns.account_topic == AccountChannelCdcContract.topic(user.id)
    assert sibling_channel.assigns.account_id == user.id
    assert sibling_channel.assigns.account_topic == AccountChannelCdcContract.topic(user.id)

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

  test "accounts:me does not deliver another user's account events" do
    user = create_user("isolated")
    other = create_user("foreign")
    {:ok, _reply, owner_channel} = subscribe_and_join(connect_user(user), "accounts:me")
    {:ok, _reply, other_channel} = subscribe_and_join(connect_user(other), "accounts:me")

    {:ok, daemon, _bootstrap} = Daemons.create(user.id, %{name: "Private bot"})
    assert :ok = AccountChannel.broadcast_daemon_created(user.id, daemon)

    assert_push "daemon_created", %{id: daemon_id}
    assert daemon_id == daemon.id
    refute_receive %Phoenix.Socket.Message{event: "daemon_created"}, 100

    leave(owner_channel)
    leave(other_channel)
  end

  test "the internal account topic is not an externally joinable account channel" do
    user = create_user("authorized")
    socket = connect_user(user)

    assert UserSocket.__channel__(AccountChannelCdcContract.topic(user.id)) == nil

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, AccountChannel, AccountChannelCdcContract.topic(user.id))

    assert {:error, %{reason: "forbidden"}} =
             AccountChannel.join("accounts:other", %{}, %Phoenix.Socket{})
  end

  test "standalone daemon principals cannot join account topics" do
    user = create_user("daemon")
    {:ok, daemon, bootstrap} = Daemons.create(user.id)

    {:ok, _daemon, reconnect_token, _credential} =
      Daemons.exchange_bootstrap(daemon.id, bootstrap)

    {:ok, socket} =
      connect(UserSocket, %{"daemon_id" => daemon.id, "reconnect_token" => reconnect_token})

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, "accounts:me")
  end

  test "missing authentication cannot join accounts:me" do
    assert {:error, %{reason: "forbidden"}} =
             AccountChannel.join("accounts:me", %{}, %Phoenix.Socket{})
  end

  test "account broadcasts use an explicit sanitized payload allowlist" do
    user = create_user("sanitized")
    {:ok, _reply, channel} = subscribe_and_join(connect_user(user), "accounts:me")
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
    {:ok, _reply, channel} = subscribe_and_join(connect_user(user), "accounts:me")

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
