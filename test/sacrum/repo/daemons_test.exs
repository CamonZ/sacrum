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

  test "revoke atomically invalidates every credential with one consistent timestamp" do
    {:ok, user} =
      Users.insert(%{
        email: "atomic-revoke@example.com",
        username: "atomic_revoke",
        password: "password123"
      })

    {:ok, daemon, bootstrap} = Daemons.create(user.id, %{name: "target"})
    assert {:ok, _, reconnect, _} = Daemons.exchange_bootstrap(daemon.id, bootstrap)

    assert {:ok, %{daemon: revoked} = result} = Daemons.revoke(daemon)

    assert revoked.id == daemon.id
    assert revoked.status == "revoked"
    assert revoked.name == "target"
    assert refute_token_material(result, [bootstrap, reconnect])

    assert Repo.aggregate(
             from(c in DaemonCredential,
               where: c.daemon_id == ^daemon.id and c.status == "active"
             ),
             :count
           ) == 0

    revoked_rows =
      Repo.all(
        from c in DaemonCredential,
          where: c.daemon_id == ^daemon.id and c.status == "revoked",
          order_by: [asc: c.inserted_at]
      )

    assert length(revoked_rows) == 2
    timestamps = Enum.map(revoked_rows, & &1.revoked_at)
    assert Enum.all?(timestamps, &(&1 != nil))
    assert Enum.uniq(timestamps) == [List.first(timestamps)]

    reconnect_row =
      Repo.one!(
        from c in DaemonCredential,
          where: c.daemon_id == ^daemon.id and c.credential_kind == "reconnect"
      )

    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, reconnect)

    assert {:error, :invalid_credentials} =
             Daemons.revalidate_reconnect(daemon.id, reconnect_row.id)
  end

  test "revoke is idempotent and a stale struct cannot resurrect access" do
    {:ok, user} =
      Users.insert(%{
        email: "idempotent-revoke@example.com",
        username: "idempotent_revoke",
        password: "password123"
      })

    {:ok, daemon, _bootstrap} = Daemons.create(user.id)
    stale = Repo.get!(Daemon, daemon.id)

    assert {:ok, first} = Daemons.revoke(stale)
    assert first.daemon.status == "revoked"

    assert {:ok, second} = Daemons.revoke(stale)
    assert second.daemon.status == "revoked"

    assert {:ok, third} = Daemons.revoke(Repo.get!(Daemon, daemon.id))
    assert third.daemon.status == "revoked"

    assert {:error, :terminal_state} = Daemons.rotate(daemon)
    assert {:error, :terminal_state} = Daemons.rotate_bootstrap(daemon)
  end

  defp refute_token_material(result, tokens) do
    inspected = inspect(result)
    refute Enum.any?(tokens, &String.contains?(inspected, &1))
    true
  end

  test "legacy enrollment evidence without enrolled_at still blocks removal" do
    {:ok, user} =
      Users.insert(%{
        email: "unregister-legacy@example.com",
        username: "unregister_legacy",
        password: "password123"
      })

    {:ok, daemon, _bootstrap} = Daemons.create(user.id)

    # Simulate a pre-migration row: reconnect evidence, no enrolled_at stamp.
    Repo.insert!(%DaemonCredential{
      daemon_id: daemon.id,
      credential_kind: "reconnect",
      token_hash: :crypto.strong_rand_bytes(32) |> Base.encode64(),
      expires_at: DateTime.add(DateTime.utc_now(), 3600)
    })

    assert {:error, :ownership_unknown} = Daemons.unregister(daemon)
    assert Repo.get!(Daemon, daemon.id).status == "pending"
  end
end
