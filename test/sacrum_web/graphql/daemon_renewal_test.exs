defmodule SacrumWeb.Graphql.DaemonRenewalTest do
  use SacrumWeb.ConnCase, async: false

  alias Sacrum.Repo
  alias Sacrum.Repo.Daemons
  alias Sacrum.Repo.Schemas.DaemonCredential
  alias SacrumWeb.UserSocket

  @renew "mutation { renewDaemonCredential { reconnectToken expiresAt } }"

  setup do
    user = create_user()
    {:ok, daemon, bootstrap} = Daemons.create(user.id)
    {:ok, _, token, credential} = Daemons.exchange_bootstrap(daemon.id, bootstrap)
    %{user: user, daemon: daemon, token: token, credential: credential, bootstrap: bootstrap}
  end

  test "returns a fresh 30-day credential and first GraphQL use revokes its predecessor", ctx do
    before = DateTime.utc_now()
    conn = request(ctx.daemon.id, ctx.token, @renew)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    payload = json_response(conn, 200)["data"]["renewDaemonCredential"]
    successor = payload["reconnectToken"]
    refute successor == ctx.token
    {:ok, expiry, _} = DateTime.from_iso8601(payload["expiresAt"])
    assert DateTime.diff(expiry, before) in 2_592_000..2_592_005
    assert {:ok, _, _} = Daemons.revalidate_reconnect(ctx.daemon.id, ctx.credential.id)
    assert request(ctx.daemon.id, ctx.token, "{ daemons { id } }").status == 200
    assert request(ctx.daemon.id, successor, "{ daemons { id } }").status == 200

    assert {:error, :invalid_credentials} =
             Daemons.authenticate_reconnect(ctx.daemon.id, ctx.token)

    assert request(ctx.daemon.id, ctx.token, @renew).status == 401

    assert :error =
             UserSocket.connect(
               %{"daemon_id" => ctx.daemon.id, "reconnect_token" => ctx.token},
               %Phoenix.Socket{},
               %{}
             )

    stored = Repo.get!(DaemonCredential, ctx.credential.id)
    assert stored.status == "revoked"
    refute Jason.encode!(Daemons.enrollment_metadata(ctx.daemon)) =~ successor
    refute Jason.encode!(Daemons.enrollment_metadata(ctx.daemon)) =~ stored.token_hash
  end

  test "a lost response can be retried and only the latest successor remains valid", ctx do
    first = renewal(ctx.daemon.id, ctx.token)
    second = renewal(ctx.daemon.id, ctx.token)
    refute first == second
    assert {:error, :invalid_credentials} = Daemons.authenticate_reconnect(ctx.daemon.id, first)
    assert {:ok, _, _} = Daemons.authenticate_reconnect(ctx.daemon.id, ctx.token)
    assert {:ok, _, _} = Daemons.authenticate_reconnect(ctx.daemon.id, second)

    assert {:error, :invalid_credentials} =
             Daemons.authenticate_reconnect(ctx.daemon.id, ctx.token)

    third = renewal(ctx.daemon.id, second)
    assert {:ok, _, _} = Daemons.authenticate_reconnect(ctx.daemon.id, third)
    assert {:error, :invalid_credentials} = Daemons.authenticate_reconnect(ctx.daemon.id, second)
  end

  test "renewal response secrets and hashes are absent from logs and safe projections", ctx do
    parent = self()

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        conn = request(ctx.daemon.id, ctx.token, @renew)
        send(parent, {:renewal, json_response(conn, 200)["data"]["renewDaemonCredential"]})
      end)

    assert_receive {:renewal, payload}
    token = payload["reconnectToken"]
    refute log =~ token
    credentials = Repo.all(DaemonCredential)
    for credential <- credentials, do: refute(log =~ credential.token_hash)
    metadata = Jason.encode!(Daemons.enrollment_metadata(ctx.daemon))
    refute metadata =~ token
    for credential <- credentials, do: refute(metadata =~ credential.token_hash)
  end

  test "account tokens cannot renew", ctx do
    response =
      build_conn()
      |> authenticate(ctx.user)
      |> post("/graphql", %{query: @renew})
      |> json_response(200)

    assert [%{"code" => "invalid_credentials"}] =
             Enum.map(response["errors"], &Map.take(&1, ["code"]))
  end

  test "bootstrap, consumed, foreign, expired, revoked, unknown and deleted credentials are rejected",
       ctx do
    {:ok, other, bootstrap} = Daemons.create(ctx.user.id)

    for {id, token} <- [
          {other.id, bootstrap},
          {ctx.daemon.id, ctx.bootstrap},
          {other.id, ctx.token},
          {Ecto.UUID.generate(), ctx.token}
        ] do
      assert %{"code" => "invalid_credentials"} = request(id, token, @renew) |> json_response(401)
    end

    Repo.update!(
      Ecto.Changeset.change(ctx.credential, expires_at: DateTime.add(DateTime.utc_now(), -1))
    )

    assert %{"code" => "invalid_credentials"} =
             request(ctx.daemon.id, ctx.token, @renew) |> json_response(401)

    Repo.update!(DaemonCredential.revoke_changeset(ctx.credential))

    assert {:error, :invalid_credentials} =
             Daemons.renew_reconnect(ctx.daemon.id, ctx.credential.id)

    Repo.delete!(ctx.daemon)

    assert {:error, :invalid_credentials} =
             Daemons.renew_reconnect(ctx.daemon.id, ctx.credential.id)

    assert Repo.get(Sacrum.Repo.Schemas.Daemon, ctx.daemon.id) == nil
  end

  defp renewal(id, token) do
    request(id, token, @renew)
    |> json_response(200)
    |> get_in(["data", "renewDaemonCredential", "reconnectToken"])
  end

  defp request(id, token, query) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("x-daemon-id", id)
    |> post("/graphql", %{query: query})
  end
end
