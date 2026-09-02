defmodule Sacrum.DaemonProvisioningSecurityTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Repo.{DaemonCredentials, Daemons, Users}

  defp user(suffix) do
    {:ok, user} =
      Users.insert(%{
        email: "daemon-#{suffix}@example.com",
        username: "daemon#{suffix}",
        password: "password123"
      })

    user
  end

  test "creation stores only a hash and scopes lookup to the owner" do
    owner = user("owner")
    other = user("other")
    assert {:ok, daemon, token} = Accounts.Daemons.create(owner.id)
    assert [credential] = DaemonCredentials.list_active_for_daemon(daemon.id)
    refute credential.token_hash == token
    assert Argon2.verify_pass(token, credential.token_hash)
    assert {:ok, found} = Accounts.Daemons.get_by(owner.id, conditions: [id: daemon.id])
    assert found.id == daemon.id
    assert Accounts.Daemons.get_by(other.id, conditions: [id: daemon.id]) == {:error, :not_found}
    assert {:ok, ^daemon} = Daemons.get(daemon.id)
  end

  test "expired credentials fail closed and rotation invalidates the previous token" do
    owner = user("lifecycle")
    assert {:ok, daemon, token} = Accounts.Daemons.create(owner.id, %{ttl: -1})
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, token)
    assert {:ok, daemon, current_token} = Accounts.Daemons.rotate(owner.id, daemon.id)
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, token)
    assert {:ok, ^daemon} = Daemons.verify_token(daemon.id, current_token)
  end

  test "generic repo and resource provide daemon CRUD and user scoping" do
    owner = user("generic")
    assert {:ok, daemon, _token} = Accounts.Daemons.create(owner.id)
    assert [listed] = Accounts.Daemons.list_by(owner.id)
    assert listed.id == daemon.id
    assert {:error, :not_found} = Daemons.get_by(conditions: [id: Ecto.UUID.generate()])
  end
end
