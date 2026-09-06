defmodule Sacrum.Repo.DaemonsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.{Daemons, Users}
  alias Sacrum.Repo.DaemonCredentials
  alias Sacrum.Repo.Schemas.DaemonCredential

  test "creates a daemon with a one-time credential and generic CRUD works" do
    {:ok, user} =
      Users.insert(%{
        email: "repo-daemon@example.com",
        username: "repo_daemon",
        password: "password123"
      })

    assert {:ok, daemon, token} = Daemons.create(user.id)
    assert {:ok, found} = Daemons.get(daemon.id)
    assert found.id == daemon.id
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, token)

    assert [%{credential_kind: "bootstrap", consumed_at: nil}] =
             DaemonCredentials.list_active_for_daemon(daemon.id)
  end

  test "rotation revokes existing credentials and preserves identity" do
    {:ok, user} =
      Users.insert(%{
        email: "rotate-daemon@example.com",
        username: "rotate_daemon",
        password: "password123"
      })

    {:ok, daemon, old_token} = Daemons.create(user.id)
    [previous] = DaemonCredentials.list_active_for_daemon(daemon.id)
    assert {:ok, rotated, new_token} = Daemons.rotate(daemon)
    assert rotated.id == daemon.id
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, old_token)

    previous = Repo.get!(DaemonCredential, previous.id)
    assert previous.status == "revoked"
    assert previous.revoked_at

    assert {:ok, _, reconnect, _} = Daemons.exchange_bootstrap(daemon.id, new_token)
    assert {:ok, _} = Daemons.verify_token(daemon.id, reconnect)

    assert Enum.any?(
             DaemonCredentials.list_active_for_daemon(daemon.id),
             &(&1.credential_kind == "reconnect")
           )
  end
end
