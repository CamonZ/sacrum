defmodule SacrumWeb.DaemonExchangeControllerTest do
  use SacrumWeb.ConnCase, async: false

  alias Sacrum.Accounts.Daemons

  setup do
    user = create_user()
    {:ok, daemon, bootstrap} = Daemons.create(user.id)
    %{daemon: daemon, bootstrap: bootstrap}
  end

  test "exchanges with only bootstrap credentials and refuses replay", ctx do
    conn =
      post(ctx.conn, "/api/daemon/exchange", %{
        daemon_id: ctx.daemon.id,
        bootstrap_token: ctx.bootstrap
      })

    result = json_response(conn, 200)
    assert result["daemon_id"] == ctx.daemon.id
    assert is_binary(result["access_token"])
    assert is_binary(result["refresh_token"])
    refute Map.has_key?(result, "reconnect_token")
    assert {:ok, access_exp, 0} = DateTime.from_iso8601(result["access_token_expires_at"])
    assert {:ok, refresh_exp, 0} = DateTime.from_iso8601(result["refresh_token_expires_at"])
    assert_in_delta DateTime.diff(access_exp, DateTime.utc_now()), 3_600, 5
    assert_in_delta DateTime.diff(refresh_exp, DateTime.utc_now()), 2_592_000, 5
    refute Map.has_key?(result, "server_endpoint")
    refute Map.has_key?(result, "socket_endpoint")
    assert get_resp_header(conn, "cache-control") == ["no-store"]

    assert {:ok, _} =
             Sacrum.Repo.Daemons.authenticate_access(ctx.daemon.id, result["access_token"])

    refute Map.has_key?(result, "token_hash")

    replay =
      post(build_conn(), "/api/daemon/exchange", %{
        daemon_id: ctx.daemon.id,
        bootstrap_token: ctx.bootstrap
      })

    assert json_response(replay, 401) == %{"error" => "invalid_credentials"}
  end

  test "refresh rotates the pair, rejects an access token and a replayed rotated token", ctx do
    exchange =
      ctx.conn
      |> post("/api/daemon/exchange", %{daemon_id: ctx.daemon.id, bootstrap_token: ctx.bootstrap})
      |> json_response(200)

    refresh = fn token ->
      post(build_conn(), "/api/daemon/refresh", %{daemon_id: ctx.daemon.id, refresh_token: token})
    end

    assert json_response(refresh.(exchange["access_token"]), 401) ==
             %{"error" => "invalid_credentials"}

    conn = refresh.(exchange["refresh_token"])
    rotated = json_response(conn, 200)
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert rotated["refresh_token"] != exchange["refresh_token"]
    assert rotated["access_token"] != exchange["access_token"]

    # previous access token died on refresh; the new one works
    assert {:error, :invalid_credentials} =
             Sacrum.Repo.Daemons.authenticate_access(ctx.daemon.id, exchange["access_token"])

    assert {:ok, _} =
             Sacrum.Repo.Daemons.authenticate_access(ctx.daemon.id, rotated["access_token"])

    # successor used: predecessor now fails
    assert json_response(refresh.(exchange["refresh_token"]), 401) ==
             %{"error" => "invalid_credentials"}

    assert %{"refresh_token" => _} = json_response(refresh.(rotated["refresh_token"]), 200)

    assert json_response(
             post(build_conn(), "/api/daemon/refresh", %{daemon_id: ctx.daemon.id}),
             400
           ) == %{"error" => "invalid_request"}
  end

  test "rejects malformed and unrelated operations without consuming bootstrap", ctx do
    for body <- [
          %{},
          %{query: "{ projects { id } }"},
          %{daemon_id: ctx.daemon.id, bootstrap_token: %{}},
          %{
            daemon_id: ctx.daemon.id,
            bootstrap_token: ctx.bootstrap,
            user_id: Ecto.UUID.generate()
          }
        ] do
      conn = post(build_conn(), "/api/daemon/exchange", body)
      assert json_response(conn, 400) == %{"error" => "invalid_request"}
    end

    conn =
      post(build_conn(), "/api/daemon/exchange?unrelated=true", %{
        daemon_id: ctx.daemon.id,
        bootstrap_token: ctx.bootstrap
      })

    assert json_response(conn, 400) == %{"error" => "invalid_request"}
    assert {:ok, _, _} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
    protected = post(build_conn(), "/graphql", %{query: "{ projects { id } }"})
    assert protected.status == 401
  end

  test "bad pairing and malformed IDs have stable sanitized errors", ctx do
    for id <- ["malformed", Ecto.UUID.generate()] do
      conn =
        post(build_conn(), "/api/daemon/exchange", %{
          daemon_id: id,
          bootstrap_token: ctx.bootstrap
        })

      assert json_response(conn, 401) == %{"error" => "invalid_credentials"}
    end
  end

  test "credential fields are filtered from ordinary Phoenix parameter logs" do
    params = %{
      "bootstrap_token" => "fixture-secret",
      "enrollmentToken" => "fixture-secret",
      "refresh_token" => "fixture-secret",
      "access_token" => "fixture-secret",
      "token_hash" => "fixture-secret",
      "daemon_id" => "visible"
    }

    filtered = Phoenix.Logger.filter_values(params)
    assert filtered["daemon_id"] == "visible"

    for field <- [
          "bootstrap_token",
          "enrollmentToken",
          "refresh_token",
          "access_token",
          "token_hash"
        ] do
      assert filtered[field] == "[FILTERED]"
    end
  end

  test "request logging redacts the submitted bootstrap", ctx do
    original_level = Logger.level()
    Logger.configure(level: :debug)

    try do
      log =
        ExUnit.CaptureLog.capture_log([level: :debug], fn ->
          conn =
            post(build_conn(), "/api/daemon/exchange", %{
              daemon_id: "malformed",
              bootstrap_token: ctx.bootstrap
            })

          assert json_response(conn, 401) == %{"error" => "invalid_credentials"}
        end)

      refute String.contains?(log, ctx.bootstrap)
      assert log =~ "[FILTERED]"
    after
      Logger.configure(level: original_level)
    end
  end
end
