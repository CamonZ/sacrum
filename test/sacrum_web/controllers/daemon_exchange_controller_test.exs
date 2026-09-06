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
    assert is_binary(result["reconnect_token"])
    assert {:ok, _, 0} = DateTime.from_iso8601(result["expires_at"])
    assert String.ends_with?(result["socket_endpoint"], "/socket/websocket")
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert {:ok, _} = Sacrum.Repo.Daemons.verify_token(ctx.daemon.id, result["reconnect_token"])
    refute Map.has_key?(result, "token_hash")

    replay =
      post(build_conn(), "/api/daemon/exchange", %{
        daemon_id: ctx.daemon.id,
        bootstrap_token: ctx.bootstrap
      })

    assert json_response(replay, 401) == %{"error" => "invalid_credentials"}
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
    assert {:ok, _, _, _} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
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
      "reconnect_token" => "fixture-secret",
      "token_hash" => "fixture-secret",
      "daemon_id" => "visible"
    }

    filtered = Phoenix.Logger.filter_values(params)
    assert filtered["daemon_id"] == "visible"

    for field <- ["bootstrap_token", "enrollmentToken", "reconnect_token", "token_hash"] do
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
