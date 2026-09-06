defmodule Sacrum.Repo.DaemonExchangeConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Sacrum.Repo
  alias Sacrum.Repo.{Daemons, Users}
  alias Sacrum.Repo.Schemas.{Daemon, DaemonCredential, User}

  setup do
    {user, daemon, bootstrap} =
      committed(fn ->
        suffix = System.unique_integer([:positive])

        {:ok, user} =
          Users.insert(%{
            email: "exchange-race-#{suffix}@example.com",
            username: "race#{suffix}",
            password: "password123"
          })

        {:ok, daemon, bootstrap} = Daemons.create(user.id)
        {user, daemon, bootstrap}
      end)

    on_exit(fn ->
      committed(fn -> Repo.delete_all(from u in User, where: u.id == ^user.id) end)
    end)

    %{daemon: daemon, bootstrap: bootstrap}
  end

  test "two database sessions contend and exactly one exchange wins", ctx do
    supervisor = start_supervised!({Task.Supervisor, []})
    parent = self()

    tasks =
      committed(fn ->
        {:ok, tasks} =
          Repo.transaction(fn ->
            Repo.one!(from d in Daemon, where: d.id == ^ctx.daemon.id, lock: "FOR UPDATE")

            tasks =
              for _ <- 1..2 do
                Task.Supervisor.async_nolink(supervisor, fn ->
                  committed(fn ->
                    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
                    send(parent, {:ready, self(), backend})

                    receive do
                      :exchange -> Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
                    end
                  end)
                end)
              end

            backends =
              for task <- tasks do
                pid = task.pid
                assert_receive {:ready, ^pid, backend}, 5_000
                backend
              end

            assert length(Enum.uniq(backends)) == 2
            Enum.each(tasks, &send(&1.pid, :exchange))
            # Do not release the daemon lock until both real connections contend.
            await_blocked(backends, System.monotonic_time(:millisecond) + 5_000)
            tasks
          end)

        tasks
      end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.count(results, &match?({:ok, _, _, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid_credentials}, &1)) == 1

    committed(fn ->
      rows = Repo.all(from c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id)
      assert length(rows) == 2

      assert Enum.count(rows, &(&1.credential_kind == "bootstrap" and not is_nil(&1.consumed_at))) ==
               1

      assert Enum.count(rows, &(&1.credential_kind == "reconnect" and &1.status == "active")) == 1
    end)
  end

  test "failure inserting reconnect rolls back bootstrap consumption", ctx do
    suffix = System.unique_integer([:positive])
    function = "fail_exchange_#{suffix}"
    trigger = "fail_exchange_trigger_#{suffix}"

    committed(fn ->
      Repo.query!("""
      CREATE FUNCTION #{function}() RETURNS trigger AS $$
      BEGIN
        SELECT token_hash INTO NEW.token_hash FROM daemon_credentials
        WHERE daemon_id = NEW.daemon_id AND credential_kind = 'bootstrap' LIMIT 1;
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql;
      """)

      Repo.query!("""
      CREATE TRIGGER #{trigger} BEFORE INSERT ON daemon_credentials
      FOR EACH ROW WHEN (NEW.credential_kind = 'reconnect' AND NEW.daemon_id = '#{ctx.daemon.id}')
      EXECUTE FUNCTION #{function}();
      """)
    end)

    try do
      committed(fn ->
        assert {:error, changeset} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
        assert Keyword.has_key?(changeset.errors, :token_hash)

        assert [bootstrap] =
                 Repo.all(from c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id)

        assert bootstrap.consumed_at == nil
        assert bootstrap.credential_kind == "bootstrap"
      end)
    after
      committed(fn ->
        Repo.query!("DROP TRIGGER #{trigger} ON daemon_credentials")
        Repo.query!("DROP FUNCTION #{function}()")
      end)
    end

    committed(fn ->
      assert {:ok, _, _, _} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
    end)
  end

  describe "revoke races" do
    test "revoke racing bootstrap exchange always ends terminal and unauthenticated", ctx do
      contenders = [
        fn -> Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap) end,
        fn -> Daemons.revoke(ctx.daemon) end
      ]

      results = race_on_daemon_lock(ctx.daemon.id, contenders)

      revoke = Enum.find(results, &match?({:ok, %{daemon: _}}, &1))
      assert {:ok, %{daemon: %{status: "revoked"}}} = revoke

      committed(fn ->
        daemon = Repo.get!(Daemon, ctx.daemon.id)
        assert daemon.status == "revoked"

        assert Repo.aggregate(
                 from(c in DaemonCredential,
                   where: c.daemon_id == ^daemon.id and c.status == "active"
                 ),
                 :count
               ) == 0

        # Even a winning exchange cannot leave a usable reconnect behind.
        exchange = Enum.find(results, &match?({:ok, _, _, _}, &1))

        if exchange do
          reconnect = elem(exchange, 2)
          assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, reconnect)
        end
      end)
    end

    test "revoke racing rotation always ends terminal with no live credentials", ctx do
      contenders = [
        fn -> Daemons.rotate_bootstrap(ctx.daemon) end,
        fn -> Daemons.revoke(ctx.daemon) end
      ]

      results = race_on_daemon_lock(ctx.daemon.id, contenders)

      assert {:ok, %{daemon: %{status: "revoked"}}} =
               Enum.find(results, &match?({:ok, %{daemon: _}}, &1))

      rotate = Enum.find(results, &match?({:ok, %{token: token}} when is_binary(token), &1))

      committed(fn ->
        daemon = Repo.get!(Daemon, ctx.daemon.id)
        assert daemon.status == "revoked"

        assert Repo.aggregate(
                 from(c in DaemonCredential,
                   where: c.daemon_id == ^daemon.id and c.status == "active"
                 ),
                 :count
               ) == 0

        # If rotation won the race, revoke still invalidated its fresh bootstrap.
        if rotate do
          token = rotate |> elem(1) |> Map.fetch!(:token)
          assert {:error, :invalid_credentials} = Daemons.exchange_bootstrap(daemon.id, token)
        end

        assert {:error, :invalid_credentials} = Daemons.rotate_bootstrap(daemon)
      end)
    end

    test "pending unregister racing bootstrap exchange never orphans and never overlaps", ctx do
      contenders = [
        fn -> Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap) end,
        fn -> Daemons.unregister(ctx.daemon) end
      ]

      results = race_on_daemon_lock(ctx.daemon.id, contenders)

      exchange = Enum.find(results, &match?({:ok, _, _, _}, &1))
      unregister = Enum.find(results, &match?({:ok, %{daemon: _}}, &1))

      committed(fn ->
        daemon = Repo.get!(Daemon, ctx.daemon.id)

        case {exchange, unregister} do
          {{:ok, _, _, _}, nil} ->
            # Exchange won: evidence committed first, removal safely refused.
            assert {:error, :ownership_unknown} = Enum.find(results, &match?({:error, _}, &1))
            assert daemon.status == "active"
            assert daemon.enrolled_at

          {nil, {:ok, _}} ->
            # Removal won: terminal tombstone; exchange failed closed.
            assert {:error, :invalid_credentials} = Enum.find(results, &match?({:error, _}, &1))
            assert daemon.status == "removed"
            assert daemon.removed_at

            assert Repo.aggregate(
                     from(c in DaemonCredential,
                       where: c.daemon_id == ^daemon.id and c.status == "active"
                     ),
                     :count
                   ) == 0
        end

        # Identity, audit rows and history are always retained.
        assert Repo.aggregate(
                 from(c in DaemonCredential, where: c.daemon_id == ^daemon.id),
                 :count
               ) >= 1
      end)
    end

    test "injected failure of the daemon status update rolls back credential invalidation", ctx do
      suffix = System.unique_integer([:positive])
      function = "fail_revoke_#{suffix}"
      trigger = "fail_revoke_trigger_#{suffix}"

      committed(fn ->
        Repo.query!("""
        CREATE FUNCTION #{function}() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'injected revoke failure';
        END;
        $$ LANGUAGE plpgsql;
        """)

        Repo.query!("""
        CREATE TRIGGER #{trigger} BEFORE UPDATE ON daemons
        FOR EACH ROW WHEN (NEW.status = 'revoked' AND OLD.status <> 'revoked' AND NEW.id = '#{ctx.daemon.id}')
        EXECUTE FUNCTION #{function}();
        """)
      end)

      try do
        committed(fn ->
          assert_raise Postgrex.Error, ~r/injected revoke failure/, fn ->
            Daemons.revoke(ctx.daemon)
          end

          # Identity and credential mutations rolled back together.
          daemon = Repo.get!(Daemon, ctx.daemon.id)
          assert daemon.status == "pending"

          assert [%{status: "active"}] =
                   Repo.all(
                     from c in DaemonCredential,
                       where: c.daemon_id == ^daemon.id and c.status == "active"
                   )
        end)
      after
        committed(fn ->
          Repo.query!("DROP TRIGGER #{trigger} ON daemons")
          Repo.query!("DROP FUNCTION #{function}()")
        end)
      end

      committed(fn ->
        assert {:ok, %{daemon: %{status: "revoked"}}} = Daemons.revoke(ctx.daemon)
      end)
    end
  end

  defp race_on_daemon_lock(daemon_id, contenders) do
    supervisor = start_supervised!({Task.Supervisor, []})
    parent = self()

    tasks =
      committed(fn ->
        {:ok, tasks} =
          Repo.transaction(fn ->
            Repo.one!(from d in Daemon, where: d.id == ^daemon_id, lock: "FOR UPDATE")

            tasks =
              for contender <- contenders do
                Task.Supervisor.async_nolink(supervisor, fn ->
                  committed(fn ->
                    %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
                    send(parent, {:ready, self(), backend})
                    contender.()
                  end)
                end)
              end

            backends =
              for task <- tasks do
                pid = task.pid
                assert_receive {:ready, ^pid, backend}, 5_000
                backend
              end

            assert length(Enum.uniq(backends)) == length(contenders)
            await_blocked(backends, System.monotonic_time(:millisecond) + 5_000)
            tasks
          end)

        tasks
      end)

    tasks |> Enum.map(&Task.await(&1, 10_000))
  end

  defp await_blocked(backends, deadline) do
    Repo.query!("SELECT pg_stat_clear_snapshot()")

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE pid = ANY($1) AND wait_event_type = 'Lock'",
        [backends]
      )

    if count != length(backends) do
      assert System.monotonic_time(:millisecond) < deadline,
             "exchange sessions did not both contend on daemon lock"

      await_blocked(backends, deadline)
    end
  end

  defp committed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
