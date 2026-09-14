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
    assert {:error, :not_found} = Daemons.unregister(other.id, daemon.id)
    assert {:ok, deleted} = Daemons.unregister(owner.id, daemon.id)
    assert deleted.id == daemon.id
    assert {:error, :not_found} = Daemons.get_by(owner.id, conditions: [id: daemon.id])
  end

  test "sets and clears a daemon concurrency limit within the owner scope" do
    {:ok, owner} =
      Users.insert(%{
        email: "accounts-daemon-limit@example.com",
        username: "accounts_daemon_limit",
        password: "password123"
      })

    {:ok, other} =
      Users.insert(%{
        email: "other-daemon-limit@example.com",
        username: "other_daemon_limit",
        password: "password123"
      })

    {:ok, daemon, _token} = Daemons.create(owner.id)

    assert {:ok, updated} = Daemons.set_max_concurrency(owner.id, daemon.id, 3)
    assert updated.max_concurrency == 3

    assert {:error, changeset} = Daemons.set_max_concurrency(owner.id, daemon.id, 0)
    assert %{max_concurrency: ["must be greater than 0"]} = errors_on(changeset)

    assert {:error, :not_found} = Daemons.set_max_concurrency(other.id, daemon.id, 2)
    assert {:ok, cleared} = Daemons.clear_max_concurrency(owner.id, daemon.id)
    assert cleared.max_concurrency == nil
  end
end
