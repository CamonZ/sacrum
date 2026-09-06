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
