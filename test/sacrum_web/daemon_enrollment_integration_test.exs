defmodule SacrumWeb.DaemonEnrollmentIntegrationTest do
  use SacrumWeb.ConnCase, async: false
  import Phoenix.ChannelTest
  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Daemon, DaemonCredential}
  alias SacrumWeb.UserSocket

  @endpoint SacrumWeb.Endpoint
  @bootstrap_fields "daemon { id } enrollmentToken expiresAt"

  setup do
    Process.flag(:trap_exit, true)
    %{owner: create_user()}
  end

  test "account provisioning becomes standalone exchange and durable reconnect", %{owner: owner} do
    bootstrap = provision(owner)
    daemon_id = bootstrap["daemon"]["id"]
    issued = exchange(daemon_id, bootstrap["enrollmentToken"])
    assert issued["daemon_id"] == daemon_id

    assert DateTime.compare(parse_time(issued["expires_at"]), parse_time(bootstrap["expiresAt"])) ==
             :gt

    channel = join_machine(issued)
    assert channel.assigns.user_id == owner.id
    refute Map.has_key?(channel.assigns, :current_user)
    disconnect(channel)
    assert Sacrum.DaemonConnectionRegistry.lookup(daemon_id) == []

    Repo.update_all(
      from(c in DaemonCredential,
        where: c.daemon_id == ^daemon_id and c.credential_kind == "bootstrap"
      ),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    reconnected = join_machine(issued)
    assert reconnected.assigns.daemon_id == daemon_id
    assert Repo.aggregate(from(d in Daemon, where: d.user_id == ^owner.id), :count) == 1
    disconnect(reconnected)
  end

  test "lost exchange response recovers only through owner rotation on the same identity", %{
    owner: owner
  } do
    bootstrap = provision(owner)
    daemon_id = bootstrap["daemon"]["id"]
    lost_response = exchange(daemon_id, bootstrap["enrollmentToken"])

    replay =
      post(build_conn(), "/api/daemon/exchange", %{
        daemon_id: daemon_id,
        bootstrap_token: bootstrap["enrollmentToken"]
      })

    assert json_response(replay, 401) == %{"error" => "invalid_credentials"}

    rotated =
      graphql(
        owner,
        "mutation { rotateDaemonCredentials(id: \"#{daemon_id}\") { #{@bootstrap_fields} } }"
      )["rotateDaemonCredentials"]

    assert rotated["daemon"]["id"] == daemon_id
    assert :error = Phoenix.ChannelTest.connect(UserSocket, machine_params(lost_response))
    recovered = exchange(daemon_id, rotated["enrollmentToken"])
    channel = join_machine(recovered)
    assert channel.assigns.daemon_id == daemon_id
    assert Repo.aggregate(from(d in Daemon, where: d.user_id == ^owner.id), :count) == 1
    credentials = Repo.all(from c in DaemonCredential, where: c.daemon_id == ^daemon_id)
    assert length(credentials) == 4

    assert Enum.count(credentials, &(&1.credential_kind == "reconnect" and &1.status == "active")) ==
             1

    disconnect(channel)
  end

  test "named lifecycle with enrollment metadata, rename, rotation, live revoke and safe unregister",
       %{
         owner: owner
       } do
    other =
      create_user(%{
        email: "lifecycle-other@example.com",
        username: "lifecycleother",
        password: "password123"
      })

    # Named creation keeps the prior contract plus name fields.
    bootstrap =
      graphql(
        owner,
        "mutation { createDaemon(name: \"  Farm One \") { daemon { id name displayName } enrollmentToken expiresAt } }"
      )["createDaemon"]

    daemon_id = bootstrap["daemon"]["id"]
    assert bootstrap["daemon"]["name"] == "Farm One"
    assert bootstrap["daemon"]["displayName"] == "Farm One"

    # First enrollment commits metadata atomically with the exchange.
    issued = exchange(daemon_id, bootstrap["enrollmentToken"])

    metadata =
      graphql(
        owner,
        "query { daemonEnrollmentMetadata(id: \"#{daemon_id}\") { status enrolledAt credentials { credentialKind status expiresAt revokedAt } } }"
      )["daemonEnrollmentMetadata"]

    assert metadata["status"] == "active"
    assert is_binary(metadata["enrolledAt"])

    assert Enum.map(metadata["credentials"], & &1["credentialKind"]) |> Enum.sort() == [
             "bootstrap",
             "reconnect"
           ]

    # Durable reconnect after a socket drop reuses the same identity.
    channel = join_machine(issued)
    assert channel.assigns.daemon_id == daemon_id
    disconnect(channel)

    reconnected = join_machine(issued)
    assert reconnected.assigns.daemon_id == daemon_id

    # Rename is owner-only; foreign callers learn nothing.
    assert %{"errors" => [%{"message" => "daemon not found"}]} =
             graphql_response(
               other,
               "mutation { renameDaemon(id: \"#{daemon_id}\", name: \"stolen\") { id } }"
             )

    assert graphql(
             owner,
             "mutation { renameDaemon(id: \"#{daemon_id}\", name: \"Farm One Prime\") { name } }"
           )["renameDaemon"]["name"] == "Farm One Prime"

    # Rotation invalidates the live session; the old credential stays dead.
    rotation_monitor = Process.monitor(reconnected.channel_pid)

    rotated =
      graphql(
        owner,
        "mutation { rotateDaemonCredentials(id: \"#{daemon_id}\") { #{@bootstrap_fields} } }"
      )["rotateDaemonCredentials"]

    assert_receive {:DOWN, ^rotation_monitor, :process, _, _}, 5_000
    assert :error = Phoenix.ChannelTest.connect(UserSocket, machine_params(issued))

    # Re-enrollment through the fresh bootstrap reconnects the same identity.
    reissued = exchange(daemon_id, rotated["enrollmentToken"])
    fresh = join_machine(reissued)
    assert fresh.assigns.daemon_id == daemon_id

    # Live-session revoke: the joined session terminates and cannot return.
    revoke_monitor = Process.monitor(fresh.channel_pid)

    revoked =
      graphql(owner, "mutation { revokeDaemon(id: \"#{daemon_id}\") { id status } }")[
        "revokeDaemon"
      ]

    assert revoked["status"] == "revoked"
    assert_receive {:DOWN, ^revoke_monitor, :process, _, _}, 5_000
    assert :error = Phoenix.ChannelTest.connect(UserSocket, machine_params(reissued))

    # Enrolled identities are never removable, even after revocation.
    assert %{"errors" => [%{"message" => refused}]} =
             graphql_response(
               owner,
               "mutation { unregisterDaemon(id: \"#{daemon_id}\") { id } }"
             )

    assert refused =~ "cannot be unregistered"

    # A second owner's never-enrolled provisioning unregisters safely, and a
    # failed foreign removal leaves its row listed for the true owner.
    pending = provision(other)
    pending_id = pending["daemon"]["id"]

    assert %{"errors" => [%{"message" => "daemon not found"}]} =
             graphql_response(
               owner,
               "mutation { unregisterDaemon(id: \"#{pending_id}\") { id } }"
             )

    assert [%{"id" => ^pending_id, "status" => "pending"}] =
             graphql(other, "query { daemons { id status } }")["daemons"]

    assert graphql(
             other,
             "mutation { unregisterDaemon(id: \"#{pending_id}\") { status removedAt } }"
           )["unregisterDaemon"]["status"] == "removed"

    assert [] == graphql(other, "query { daemons { id } }")["daemons"]

    # History and the revoked identity remain readable for the owner.
    assert [%{"id" => ^daemon_id, "status" => "revoked"}] =
             graphql(owner, "query { daemons { id status } }")["daemons"]

    assert Repo.get!(Daemon, daemon_id).name == "Farm One Prime"
  end

  defp provision(owner),
    do: graphql(owner, "mutation { createDaemon { #{@bootstrap_fields} } }")["createDaemon"]

  defp graphql(owner, query) do
    response = graphql_response(owner, query)
    refute Map.has_key?(response, "errors")
    response["data"]
  end

  defp graphql_response(owner, query) do
    build_conn()
    |> authenticate(owner)
    |> post("/graphql", %{query: query})
    |> json_response(200)
  end

  defp exchange(daemon_id, token) do
    # A new unauthenticated connection models the standalone machine boundary.
    conn =
      post(build_conn(), "/api/daemon/exchange", %{daemon_id: daemon_id, bootstrap_token: token})

    assert get_req_header(conn, "authorization") == []
    json_response(conn, 200)
  end

  defp join_machine(issued) do
    {:ok, socket} = Phoenix.ChannelTest.connect(UserSocket, machine_params(issued))
    {:ok, _, channel} = subscribe_and_join(socket, "daemon:#{issued["daemon_id"]}")
    channel
  end

  defp machine_params(issued),
    do: %{"daemon_id" => issued["daemon_id"], "reconnect_token" => issued["reconnect_token"]}

  defp disconnect(channel) do
    pid = channel.channel_pid
    monitor = Process.monitor(pid)
    leave(channel)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
  end

  defp parse_time(value) do
    {:ok, datetime, 0} = DateTime.from_iso8601(value)
    datetime
  end
end
