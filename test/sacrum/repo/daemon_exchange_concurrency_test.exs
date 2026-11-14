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
    assert Enum.count(results, &match?({:ok, _, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :invalid_credentials}, &1)) == 1

    committed(fn ->
      rows = Repo.all(from c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id)
      assert length(rows) == 3

      assert Enum.count(rows, &(&1.credential_kind == "bootstrap" and not is_nil(&1.consumed_at))) ==
               1

      for kind <- ["access", "refresh"] do
        assert Enum.count(rows, &(&1.credential_kind == kind and &1.status == "active")) == 1
      end
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
      FOR EACH ROW WHEN (NEW.credential_kind = 'refresh' AND NEW.daemon_id = '#{ctx.daemon.id}')
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
      assert {:ok, _, _} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
    end)
  end

  describe "unregister races" do
    test "unregister racing bootstrap exchange always leaves the identity absent", ctx do
      contenders = [
        fn -> Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap) end,
        fn -> Daemons.unregister(ctx.daemon) end
      ]

      results = race_on_daemon_lock(ctx.daemon.id, contenders)

      delete = Enum.find(results, &match?({:ok, %{daemon: _}}, &1))
      assert {:ok, %{daemon: %{id: id}}} = delete

      committed(fn ->
        assert id == ctx.daemon.id
        assert Repo.get(Daemon, ctx.daemon.id) == nil

        assert Repo.aggregate(
                 from(c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id),
                 :count
               ) == 0

        exchange = Enum.find(results, &match?({:ok, _, _}, &1))

        if exchange do
          {:ok, _, pair} = exchange

          assert {:error, :invalid_credentials} =
                   Daemons.authenticate_access(ctx.daemon.id, pair.access_token)

          assert {:error, :invalid_credentials} =
                   Daemons.refresh(ctx.daemon.id, pair.refresh_token)
        end
      end)
    end

    test "injected delete failure rolls back daemon and credential deletion", ctx do
      suffix = System.unique_integer([:positive])
      function = "fail_delete_#{suffix}"
      trigger = "fail_delete_trigger_#{suffix}"

      committed(fn ->
        Repo.query!("""
        CREATE FUNCTION #{function}() RETURNS trigger AS $$
        BEGIN
          RAISE EXCEPTION 'injected removal failure';
        END;
        $$ LANGUAGE plpgsql;
        """)

        Repo.query!("""
        CREATE TRIGGER #{trigger} BEFORE DELETE ON daemons
        FOR EACH ROW WHEN (OLD.id = '#{ctx.daemon.id}')
        EXECUTE FUNCTION #{function}();
        """)
      end)

      try do
        committed(fn ->
          assert_raise Postgrex.Error, ~r/injected removal failure/, fn ->
            Daemons.unregister(ctx.daemon)
          end

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
        assert {:ok, %{daemon: %{status: "pending"}}} = Daemons.unregister(ctx.daemon)
        assert Repo.get(Daemon, ctx.daemon.id) == nil

        assert Repo.aggregate(
                 from(c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id),
                 :count
               ) == 0
      end)
    end
  end

  test "temporary database failure on refresh is retryable and does not revoke the presented token",
       ctx do
    pair =
      committed(fn ->
        {:ok, _, pair} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
        pair
      end)

    suffix = System.unique_integer([:positive])
    function = "fail_refresh_#{suffix}"
    trigger = "fail_refresh_trigger_#{suffix}"

    committed(fn ->
      Repo.query!(
        "CREATE FUNCTION #{function}() RETURNS trigger AS $$ BEGIN RAISE EXCEPTION 'temporary refresh failure'; END; $$ LANGUAGE plpgsql"
      )

      Repo.query!(
        "CREATE TRIGGER #{trigger} BEFORE INSERT ON daemon_credentials FOR EACH ROW WHEN (NEW.credential_kind = 'refresh' AND NEW.predecessor_id IS NOT NULL) EXECUTE FUNCTION #{function}()"
      )
    end)

    try do
      committed(fn ->
        assert {:error, :unavailable} = Daemons.refresh(ctx.daemon.id, pair.refresh_token)
        assert {:ok, _} = Daemons.authenticate_access(ctx.daemon.id, pair.access_token)
      end)
    after
      committed(fn ->
        Repo.query!("DROP TRIGGER #{trigger} ON daemon_credentials")
        Repo.query!("DROP FUNCTION #{function}()")
      end)
    end

    committed(fn ->
      assert {:ok, _, _} = Daemons.refresh(ctx.daemon.id, pair.refresh_token)
    end)
  end

  test "two concurrent refreshes with the same refresh token leave exactly one usable pair",
       ctx do
    pair =
      committed(fn ->
        {:ok, _, pair} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
        pair
      end)

    results =
      race_on_daemon_lock(ctx.daemon.id, [
        fn -> Daemons.refresh(ctx.daemon.id, pair.refresh_token) end,
        fn -> Daemons.refresh(ctx.daemon.id, pair.refresh_token) end
      ])

    # Serialized on the daemon row: the second presentation is lost-response
    # recovery, which revokes the unused successor issued to the first.
    assert [{:ok, _, first}, {:ok, _, second}] = results

    committed(fn ->
      usable =
        for p <- [first, second],
            match?({:ok, _}, Daemons.authenticate_access(ctx.daemon.id, p.access_token)),
            do: p

      assert length(usable) == 1

      successors =
        Repo.all(
          from c in DaemonCredential,
            where:
              c.daemon_id == ^ctx.daemon.id and c.credential_kind == "refresh" and
                not is_nil(c.predecessor_id)
        )

      assert length(successors) == 2
      assert Enum.count(successors, &(&1.status == "active")) == 1
      assert Enum.count(successors, &(&1.status == "revoked")) == 1
    end)
  end

  test "refresh racing rotation or deletion cannot leave a usable losing credential", ctx do
    for operation <- [:rotate, :unregister] do
      {daemon, pair} =
        committed(fn ->
          {:ok, daemon, bootstrap} = Daemons.create(ctx.daemon.user_id)
          {:ok, _, pair} = Daemons.exchange_bootstrap(daemon.id, bootstrap)
          {daemon, pair}
        end)

      [refresh, lifecycle] =
        race_on_daemon_lock(daemon.id, [
          fn -> Daemons.refresh(daemon.id, pair.refresh_token) end,
          fn -> apply(Daemons, operation, [daemon]) end
        ])

      assert {:ok, _} = lifecycle

      committed(fn ->
        case refresh do
          {:ok, _, new_pair} ->
            assert {:error, :invalid_credentials} =
                     Daemons.authenticate_access(daemon.id, new_pair.access_token)

            assert {:error, :invalid_credentials} =
                     Daemons.refresh(daemon.id, new_pair.refresh_token)

          {:error, :invalid_credentials} ->
            :ok
        end

        assert {:error, :invalid_credentials} =
                 Daemons.authenticate_access(daemon.id, pair.access_token)

        assert {:error, :invalid_credentials} = Daemons.refresh(daemon.id, pair.refresh_token)
      end)
    end
  end

  defp race_on_daemon_lock(daemon_id, contenders) do
    supervisor = start_supervised!({Task.Supervisor, []}, id: make_ref())
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
