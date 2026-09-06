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
end
