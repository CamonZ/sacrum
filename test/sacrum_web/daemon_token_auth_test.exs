defmodule SacrumWeb.DaemonTokenAuthTest do
  @moduledoc """
  Request-level guarantees of daemon access-token authentication: no Argon2,
  no transaction and no row lock on the request path, hostile Authorization
  headers never produce a 500, and issued tokens are unique and resolve by
  SHA-256 hash.
  """

  use SacrumWeb.ConnCase, async: false
  use ExUnitProperties

  import Ecto.Query

  alias Sacrum.Accounts.Daemons
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.DaemonCredential

  setup do
    user = create_user()
    {:ok, daemon, bootstrap} = Daemons.create(user.id)
    {:ok, _daemon, pair} = Daemons.exchange_bootstrap(daemon.id, bootstrap)
    %{user: user, daemon: daemon, pair: pair}
  end

  defp daemon_conn(daemon_id, token) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("x-daemon-id", daemon_id)
  end

  test "a valid access token authenticates a GraphQL request with one SELECT, no Argon2, no transaction, no lock",
       ctx do
    test_pid = self()

    :telemetry.attach(
      "daemon-token-auth-#{inspect(test_pid)}",
      [:sacrum, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if self() == test_pid, do: send(test_pid, {:repo_query, query})
      end,
      nil
    )

    :erlang.trace(self(), true, [:call])
    Code.ensure_loaded(Argon2)
    :erlang.trace_pattern({Argon2, :_, :_}, true, [:local])

    on_exit(fn ->
      :telemetry.detach("daemon-token-auth-#{inspect(test_pid)}")
    end)

    conn =
      daemon_conn(ctx.daemon.id, ctx.pair.access_token)
      |> post("/graphql", %{query: "{ daemons { id } }"})

    assert [%{"id" => id}] = json_response(conn, 200)["data"]["daemons"]
    assert id == ctx.daemon.id

    :erlang.trace(self(), false, [:call])
    refute_received {:trace, _, :call, _}

    queries = drain_queries()
    assert [auth | rest] = queries
    assert auth =~ ~r/^SELECT .* FROM "daemon_credentials"/s
    refute Enum.any?(queries, &(&1 =~ ~r/FOR UPDATE/i))
    refute Enum.any?(queries, &(&1 =~ ~r/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i))
    refute Enum.any?(rest, &(&1 =~ "daemon_credentials"))
  end

  test "an expired access token is rejected and its refresh token is not a request credential",
       ctx do
    Repo.update_all(
      from(c in DaemonCredential,
        where: c.daemon_id == ^ctx.daemon.id and c.credential_kind == "access"
      ),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1)]
    )

    for token <- [ctx.pair.access_token, ctx.pair.refresh_token] do
      conn =
        daemon_conn(ctx.daemon.id, token) |> post("/graphql", %{query: "{ daemons { id } }"})

      assert json_response(conn, 401)["code"] == "invalid_credentials"
    end
  end

  test "an access token presented with another daemon's X-Daemon-ID is rejected", ctx do
    {:ok, other, _} = Daemons.create(ctx.user.id)

    conn =
      daemon_conn(other.id, ctx.pair.access_token)
      |> post("/graphql", %{query: "{ daemons { id } }"})

    assert json_response(conn, 401)["code"] == "invalid_credentials"
  end

  property "random Authorization headers always yield 401, never 500", ctx do
    header =
      one_of([
        constant(nil),
        map(string(:printable, max_length: 40), &"Basic #{&1}"),
        constant("Bearer"),
        constant("Bearer "),
        map(string(:printable, max_length: 40), &"Bearer #{&1}"),
        map(string(:alphanumeric, min_length: 1, max_length: 60), &"Bearer sacd_#{&1}"),
        map(binary(max_length: 64), &"Bearer #{&1}"),
        map(binary(max_length: 64), & &1),
        map(integer(1..4), &"Bearer sacd_#{String.duplicate("A", &1 * 40_000)}")
      ])

    daemon_header = one_of([constant(nil), constant(ctx.daemon.id), string(:printable)])

    check all(auth <- header, daemon_id <- daemon_header, max_runs: 60) do
      conn = build_conn()
      conn = if auth, do: put_req_header(conn, "authorization", auth), else: conn
      conn = if daemon_id, do: put_req_header(conn, "x-daemon-id", daemon_id), else: conn

      conn = post(conn, "/graphql", %{query: "{ daemons { id } }"})
      assert conn.status == 401
    end
  end

  property "generated tokens are unique and resolve through their SHA-256 hash", ctx do
    check all(count <- integer(1..4), max_runs: 15) do
      tokens =
        for _ <- 1..count, reduce: [] do
          acc ->
            {:ok, daemon, bootstrap} = Daemons.create(ctx.user.id)
            {:ok, _, pair} = Daemons.exchange_bootstrap(daemon.id, bootstrap)
            {:ok, _, rotated} = Daemons.refresh(daemon.id, pair.refresh_token)

            [
              {"bootstrap", bootstrap},
              {"access", pair.access_token},
              {"refresh", pair.refresh_token},
              {"access", rotated.access_token},
              {"refresh", rotated.refresh_token} | acc
            ]
        end

      values = Enum.map(tokens, &elem(&1, 1))
      assert length(Enum.uniq(values)) == length(values)

      for {kind, value} <- tokens do
        hash = DaemonCredential.hash_token(value)
        assert [row] = Repo.all(from c in DaemonCredential, where: c.token_hash == ^hash)
        assert row.credential_kind == kind
        refute String.contains?(row.token_hash, value)
      end
    end
  end

  defp drain_queries do
    receive do
      {:repo_query, query} -> [query | drain_queries()]
    after
      0 -> []
    end
  end
end
