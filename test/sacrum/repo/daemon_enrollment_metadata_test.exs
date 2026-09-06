defmodule Sacrum.Repo.DaemonEnrollmentMetadataTest do
  @moduledoc """
  Database-backed evidence for daemon naming and enrollment metadata:
  concurrent duplicate-name writers, transactional exchange failure leaving
  no partial enrollment state, the raw database uniqueness constraint, and
  migration rollback/reapply behavior for legacy unnamed rows.

  Race and rollback fixtures use separate committed database sessions,
  following the merged exchange race-test patterns.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Sacrum.Repo
  alias Sacrum.Repo.{Daemons, Users}
  alias Sacrum.Repo.Schemas.{Daemon, DaemonCredential, User}

  @migration_version 20_260_906_133_957
  @migration_module Sacrum.Repo.Migrations.AddNamesAndEnrollmentToDaemons

  setup do
    {user, daemon, bootstrap} =
      committed(fn ->
        suffix = unique_suffix()

        {:ok, user} =
          Users.insert(%{
            email: "metadata-race-#{suffix}@example.com",
            username: "metarace#{suffix}",
            password: "password123"
          })

        {:ok, daemon, bootstrap, _credential} = Daemons.create_bootstrap(user.id)
        {user, daemon, bootstrap}
      end)

    on_exit(fn ->
      committed(fn -> Repo.delete_all(from u in User, where: u.id == ^user.id) end)
    end)

    %{user: user, daemon: daemon, bootstrap: bootstrap}
  end

  test "concurrent same-name creators serialize and exactly one wins", ctx do
    supervisor = start_supervised!({Task.Supervisor, []})

    tasks =
      for _i <- 1..2 do
        Task.Supervisor.async_nolink(supervisor, fn ->
          committed(fn -> Daemons.create_bootstrap(ctx.user.id, %{name: "Race Box"}) end)
        end)
      end

    results = Enum.map(tasks, &Task.await(&1, 15_000))

    assert Enum.count(results, &match?({:ok, _, _, _}, &1)) == 1

    errors =
      results
      |> Enum.filter(&match?({:error, _}, &1))
      |> Enum.map(&elem(&1, 1))
      |> Enum.map(&field_errors/1)

    assert [%{name: ["has already been taken"]}] = errors

    committed(fn ->
      named =
        Repo.all(from d in Daemon, where: d.user_id == ^ctx.user.id and d.name == "Race Box")

      assert length(named) == 1
    end)
  end

  test "exchange failure rolls back enrollment metadata with the bootstrap", ctx do
    suffix = System.unique_integer([:positive])
    function = "fail_enroll_#{suffix}"
    trigger = "fail_enroll_trigger_#{suffix}"

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

        daemon = Repo.get!(Daemon, ctx.daemon.id)
        assert daemon.enrolled_at == nil
        assert daemon.status == "pending"

        assert [bootstrap_row] =
                 Repo.all(from c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id)

        assert bootstrap_row.consumed_at == nil
      end)
    after
      committed(fn ->
        Repo.query!("DROP TRIGGER #{trigger} ON daemon_credentials")
        Repo.query!("DROP FUNCTION #{function}()")
      end)
    end

    committed(fn ->
      assert {:ok, daemon, _, _} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
      assert daemon.enrolled_at
      assert daemon.status == "active"
    end)
  end

  test "database constraint rejects duplicate normalized names regardless of changesets", ctx do
    committed(fn ->
      Repo.insert!(%Daemon{user_id: ctx.user.id, name: "Case Box"})

      assert_raise Ecto.ConstraintError, ~r/daemons_user_id_lower_name_index/, fn ->
        Repo.insert!(%Daemon{user_id: ctx.user.id, name: "case box"})
      end

      # Multiple unnamed rows for one owner remain valid: legacy compatibility.
      Repo.insert!(%Daemon{user_id: ctx.user.id})
      Repo.insert!(%Daemon{user_id: ctx.user.id})

      suffix = unique_suffix()

      {:ok, other} =
        Users.insert(%{
          email: "metadata-db-other-#{suffix}@example.com",
          username: "metadbother#{suffix}",
          password: "password123"
        })

      Repo.insert!(%Daemon{user_id: other.id, name: "case box"})
      Repo.delete(other)
    end)
  end

  test "migration rollback and reapply keep legacy unnamed rows valid", ctx do
    legacy_id =
      committed(fn ->
        # A legacy-style row: no name and no enrollment evidence.
        {:ok, legacy} =
          %Daemon{user_id: ctx.user.id}
          |> Daemon.create_changeset(%{})
          |> Repo.insert()

        assert legacy.name == nil
        assert legacy.enrolled_at == nil
        legacy.id
      end)

    rollback_and_reapply!()

    committed(fn ->
      # Legacy rows stay unnamed and never collide after the index returns.
      {:ok, another} =
        %Daemon{user_id: ctx.user.id}
        |> Daemon.create_changeset(%{})
        |> Repo.insert()

      assert another.name == nil
      assert Repo.get!(Daemon, legacy_id).name == nil

      assert MapSet.subset?(MapSet.new(["name", "enrolled_at"]), MapSet.new(daemon_columns()))
    end)
  end

  defp unique_suffix,
    do: "#{System.unique_integer([:positive])}#{System.system_time(:millisecond)}"

  defp field_errors(changeset),
    do: Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)

  defp rollback_and_reapply! do
    # Migration modules under priv/ are not compiled into the test build.
    Code.eval_file(
      Path.expand(
        "../../../priv/repo/migrations/20260906133957_add_names_and_enrollment_to_daemons.exs",
        __DIR__
      )
    )

    Sandbox.unboxed_run(Repo, fn ->
      Ecto.Migrator.run(Repo, [{@migration_version, @migration_module}], :down,
        all: true,
        log: false,
        migration_lock: false
      )

      Ecto.Migrator.run(Repo, [{@migration_version, @migration_module}], :up,
        all: true,
        log: false,
        migration_lock: false
      )

      :ok
    end)
  end

  defp daemon_columns do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = 'daemons'"
      )

    Enum.map(rows, &List.first/1)
  end

  defp committed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
