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
end
