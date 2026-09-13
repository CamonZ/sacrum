defmodule Sacrum.Repo.DaemonsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.{Daemons, Users}
  alias Sacrum.Repo.DaemonCredentials
  alias Sacrum.Repo.Schemas.{Daemon, DaemonCredential}

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

    assert {:ok, %{daemon: rotated, token: new_token}} = Daemons.rotate_bootstrap(daemon)

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

  test "exchange records first enrollment and rotation preserves it" do
    {:ok, user} =
      Users.insert(%{
        email: "enroll-daemon@example.com",
        username: "enroll_daemon",
        password: "password123"
      })

    {:ok, daemon, bootstrap, _credential} = Daemons.create_bootstrap(user.id)
    assert daemon.status == "pending"
    assert daemon.enrolled_at == nil

    first_exchange = DateTime.add(DateTime.utc_now(), -60)

    assert {:ok, enrolled, _, _} =
             Daemons.exchange_bootstrap(daemon.id, bootstrap, now: first_exchange)

    assert enrolled.id == daemon.id
    assert enrolled.enrolled_at == first_exchange
    assert enrolled.status == "active"

    {:ok, %{daemon: rotated, token: new_bootstrap}} = Daemons.rotate_bootstrap(daemon)
    assert rotated.id == daemon.id
    assert rotated.enrolled_at == first_exchange

    assert {:ok, reenrolled, _, _} = Daemons.exchange_bootstrap(daemon.id, new_bootstrap)
    assert reenrolled.enrolled_at == first_exchange
    assert reenrolled.status == "active"
  end

  test "unregister atomically removes the daemon and cascaded credentials" do
    {:ok, user} =
      Users.insert(%{
        email: "atomic-delete@example.com",
        username: "atomic_delete",
        password: "password123"
      })

    {:ok, daemon, bootstrap} = Daemons.create(user.id, %{name: "target"})
    assert {:ok, _, reconnect, _} = Daemons.exchange_bootstrap(daemon.id, bootstrap)

    assert {:ok, %{daemon: deleted} = result} = Daemons.unregister(daemon)

    assert deleted.id == daemon.id
    assert deleted.status == "active"
    assert deleted.name == "target"
    assert refute_token_material(result, [bootstrap, reconnect])
    assert Repo.get(Daemon, daemon.id) == nil

    assert Repo.aggregate(from(c in DaemonCredential, where: c.daemon_id == ^daemon.id), :count) ==
             0

    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, reconnect)
    assert {:error, :invalid_credentials} = Daemons.exchange_bootstrap(daemon.id, bootstrap)
    assert {:error, :invalid_credentials} = Daemons.rotate_bootstrap(daemon)
  end

  test "unregister is not-found on repeat and a stale struct cannot resurrect access" do
    {:ok, user} =
      Users.insert(%{
        email: "repeat-delete@example.com",
        username: "repeat_delete",
        password: "password123"
      })

    {:ok, daemon, _bootstrap} = Daemons.create(user.id)
    stale = Repo.get!(Daemon, daemon.id)

    assert {:ok, first} = Daemons.unregister(stale)
    assert first.daemon.id == daemon.id
    assert {:error, :not_found} = Daemons.unregister(stale)
    assert Repo.get(Daemon, daemon.id) == nil
    assert {:error, :invalid_credentials} = Daemons.rotate(daemon)
    assert {:error, :invalid_credentials} = Daemons.rotate_bootstrap(daemon)
  end

  test "unregister preserves the daemon-keyed active-work refusal" do
    {:ok, user} =
      Users.insert(%{
        email: "active-work-delete@example.com",
        username: "active_work_delete",
        password: "password123"
      })

    {:ok, daemon, bootstrap} = Daemons.create(user.id)

    assert {:error, :active_work} =
             Daemons.unregister(daemon, active_work?: fn _daemon -> true end)

    assert Repo.get(Daemon, daemon.id).status == "pending"

    assert Repo.aggregate(from(c in DaemonCredential, where: c.daemon_id == ^daemon.id), :count) ==
             1

    assert {:ok, _daemon, _token, _credential} =
             Daemons.exchange_bootstrap(daemon.id, bootstrap)
  end

  defp refute_token_material(result, tokens) do
    inspected = inspect(result)
    refute Enum.any?(tokens, &String.contains?(inspected, &1))
    true
  end
end
