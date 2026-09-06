defmodule Sacrum.Accounts.DaemonsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.Daemons
  alias Sacrum.Repo.Users

  test "reads and mutates only daemons owned by the user" do
    {:ok, owner} =
      Users.insert(%{
        email: "accounts-daemon@example.com",
        username: "accounts_daemon",
        password: "password123"
      })

    {:ok, other} =
      Users.insert(%{
        email: "other-daemon@example.com",
        username: "other_daemon",
        password: "password123"
      })

    {:ok, daemon, _token} = Daemons.create(owner.id)

    assert {:ok, _} = Daemons.get_by(owner.id, conditions: [id: daemon.id])
    assert {:error, :not_found} = Daemons.get_by(other.id, conditions: [id: daemon.id])
    assert {:error, :not_found} = Daemons.rotate(other.id, daemon.id)
    assert {:error, :not_found} = Daemons.revoke(other.id, daemon.id)
    assert {:ok, _} = Daemons.revoke(owner.id, daemon.id)
  end

  test "rename and enrollment reads are owner-scoped" do
    {:ok, owner} =
      Users.insert(%{
        email: "accounts-rename@example.com",
        username: "accounts_rename",
        password: "password123"
      })

    {:ok, other} =
      Users.insert(%{
        email: "accounts-rename-other@example.com",
        username: "accounts_rename_other",
        password: "password123"
      })

    {:ok, daemon, _token} = Daemons.create(owner.id, %{name: "box"})

    assert {:ok, renamed} = Daemons.rename(owner.id, daemon.id, %{name: "box two"})
    assert renamed.name == "box two"
    assert renamed.user_id == owner.id

    assert {:error, :not_found} = Daemons.rename(other.id, daemon.id, %{name: "stolen"})

    assert {:ok, metadata} = Daemons.enrollment(owner.id, daemon.id)
    assert metadata.daemon_id == daemon.id
    assert metadata.enrolled_at == nil
    assert metadata.status == "pending"

    assert {:error, :not_found} = Daemons.enrollment(other.id, daemon.id)

    persisted = Repo.get!(Sacrum.Repo.Schemas.Daemon, daemon.id)
    assert persisted.name == "box two"
  end

  test "create accepts the documented name policy and rejects invalid names" do
    {:ok, owner} =
      Users.insert(%{
        email: "accounts-name@example.com",
        username: "accounts_name",
        password: "password123"
      })

    assert {:ok, daemon, _token} = Daemons.create(owner.id, %{name: "  trim me  "})
    assert daemon.name == "trim me"

    assert {:error, changeset} = Daemons.create(owner.id, %{name: "   "})
    assert %{name: [_]} = errors_on(changeset)
  end

  describe "unregister/2 work guards" do
    setup do
      {:ok, owner} =
        Users.insert(%{
          email: "accounts-unregister@example.com",
          username: "accounts_unreg",
          password: "password123"
        })

      {:ok, other} =
        Users.insert(%{
          email: "accounts-unreg-other@example.com",
          username: "accounts_unreg2",
          password: "password123"
        })

      {:ok, daemon, bootstrap, _credential} =
        Daemons.create_bootstrap(owner.id, %{name: "guard box"})

      %{owner: owner, other: other, daemon: daemon, bootstrap: bootstrap}
    end

    test "removes never-enrolled provisioning without disclosing foreign records", ctx do
      assert {:error, :not_found} = Daemons.unregister(ctx.other.id, ctx.daemon.id)

      assert {:ok, removed} = Daemons.unregister(ctx.owner.id, ctx.daemon.id)
      assert removed.status == "removed"

      # Idempotent owner retry; foreign caller still learns nothing.
      assert {:ok, _} = Daemons.unregister(ctx.owner.id, ctx.daemon.id)
      assert {:error, :not_found} = Daemons.unregister(ctx.other.id, ctx.daemon.id)
      assert {:error, :not_found} = Daemons.unregister(Ecto.UUID.generate(), ctx.daemon.id)
    end

    test "a connected session blocks removal with active_work until it disconnects", ctx do
      :ok =
        Sacrum.DaemonConnectionRegistry.register(ctx.daemon.id, %{
          user_id: ctx.owner.id,
          credential_id: Ecto.UUID.generate()
        })

      assert {:error, :active_work} = Daemons.unregister(ctx.owner.id, ctx.daemon.id)
      assert Repo.get!(Sacrum.Repo.Schemas.Daemon, ctx.daemon.id).status == "pending"

      :ok = Sacrum.DaemonConnectionRegistry.unregister(ctx.daemon.id)
      assert {:ok, _} = Daemons.unregister(ctx.owner.id, ctx.daemon.id)
    end

    test "disconnect alone cannot make enrolled identities removable", ctx do
      assert {:ok, _, reconnect, _} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)

      :ok =
        Sacrum.DaemonConnectionRegistry.register(ctx.daemon.id, %{
          user_id: ctx.owner.id,
          credential_id: Ecto.UUID.generate()
        })

      assert {:error, :active_work} = Daemons.unregister(ctx.owner.id, ctx.daemon.id)

      :ok = Sacrum.DaemonConnectionRegistry.unregister(ctx.daemon.id)

      assert {:error, :ownership_unknown} = Daemons.unregister(ctx.owner.id, ctx.daemon.id)
      daemon = Repo.get!(Sacrum.Repo.Schemas.Daemon, ctx.daemon.id)
      assert daemon.status == "active"
      assert daemon.name == "guard box"

      # Active fleet listing still shows the enrolled daemon.
      assert Enum.any?(Daemons.list_fleet(ctx.owner.id), &(&1.id == ctx.daemon.id))
      assert is_binary(reconnect)
    end

    test "terminal identities cannot be renamed back into service", ctx do
      assert {:ok, _} = Daemons.revoke(ctx.owner.id, ctx.daemon.id)
      assert {:error, :terminal_state} = Daemons.rename(ctx.owner.id, ctx.daemon.id, %{name: "x"})

      assert {:ok, _} = Daemons.unregister(ctx.owner.id, ctx.daemon.id)
      assert {:error, :terminal_state} = Daemons.rename(ctx.owner.id, ctx.daemon.id, %{name: "y"})
      assert Repo.get!(Sacrum.Repo.Schemas.Daemon, ctx.daemon.id).name == "guard box"
    end
  end
end
