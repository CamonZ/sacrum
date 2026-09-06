defmodule SacrumWeb.DaemonEnrollmentIntegrationTest do
  use SacrumWeb.ConnCase, async: false
  import Phoenix.ChannelTest
  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Daemon, DaemonCredential}
  alias SacrumWeb.UserSocket

  @endpoint SacrumWeb.Endpoint
  @bootstrap_fields "daemon { id } enrollmentToken serverEndpoint expiresAt"

  setup do
    Process.flag(:trap_exit, true)
    %{owner: create_user()}
  end

  test "account provisioning becomes standalone exchange and durable reconnect", %{owner: owner} do
    bootstrap = provision(owner)
    daemon_id = bootstrap["daemon"]["id"]
    issued = exchange(daemon_id, bootstrap["enrollmentToken"])
    assert issued["daemon_id"] == daemon_id
    assert issued["server_endpoint"] == bootstrap["serverEndpoint"]

    assert DateTime.compare(parse_time(issued["expires_at"]), parse_time(bootstrap["expiresAt"])) ==
             :gt

    assert String.ends_with?(issued["socket_endpoint"], "/socket/websocket")

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

  defp provision(owner),
    do: graphql(owner, "mutation { createDaemon { #{@bootstrap_fields} } }")["createDaemon"]

  defp graphql(owner, query) do
    response =
      build_conn()
      |> authenticate(owner)
      |> post("/graphql", %{query: query})
      |> json_response(200)

    refute Map.has_key?(response, "errors")
    response["data"]
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
