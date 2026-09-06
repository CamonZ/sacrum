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

    assert {:ok, %{daemon: rotated, token: new_token, invalidated_credential_ids: ids}} =
             Daemons.rotate_bootstrap(daemon)

    assert rotated.id == daemon.id
    assert ids == [previous.id]
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

  test "rename applies the shared name policy without touching identity or credentials" do
    {:ok, user} =
      Users.insert(%{
        email: "rename-daemon@example.com",
        username: "rename_daemon",
        password: "password123"
      })

    {:ok, daemon, bootstrap, _credential} = Daemons.create_bootstrap(user.id)
    assert {:ok, renamed} = Daemons.rename(daemon, %{name: "  render-box  "})
    assert renamed.name == "render-box"
    assert renamed.id == daemon.id
    assert renamed.user_id == user.id
    assert renamed.status == daemon.status

    assert [%{credential_kind: "bootstrap"}] = DaemonCredentials.list_active_for_daemon(daemon.id)
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, "sacd_not-a-token")
    assert {:ok, _, _, _} = Daemons.exchange_bootstrap(daemon.id, bootstrap)

    assert {:error, changeset} = Daemons.rename(daemon, %{name: String.duplicate("x", 101)})
    assert %{name: [_]} = errors_on(changeset)

    assert {:ok, cleared} = Daemons.rename(renamed, %{name: nil})
    assert cleared.name == nil
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

    assert {:ok, %{daemon: revoked, invalidated_credential_ids: ids} = result} =
             Daemons.revoke(daemon)

    assert revoked.id == daemon.id
    assert revoked.status == "revoked"
    assert revoked.name == "target"
    # The consumed bootstrap and the live reconnect are both invalidated.
    assert length(ids) == 2
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

    reconnect_id = List.last(ids)
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, reconnect)
    assert {:error, :invalid_credentials} = Daemons.revalidate_reconnect(daemon.id, reconnect_id)
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
    assert first.invalidated_credential_ids != []

    # A stale pre-revoke struct must not re-enable anything.
    assert {:ok, second} = Daemons.revoke(stale)
    assert second.daemon.status == "revoked"
    assert second.invalidated_credential_ids == []

    assert {:ok, third} = Daemons.revoke(Repo.get!(Daemon, daemon.id))
    assert third.daemon.status == "revoked"
    assert third.invalidated_credential_ids == []

    assert {:error, :invalid_credentials} = Daemons.rotate(daemon)
    assert {:error, :invalid_credentials} = Daemons.rotate_bootstrap(daemon)
  end

  test "terminal identities cannot rotate or reauthenticate after revoke" do
    {:ok, user} =
      Users.insert(%{
        email: "terminal-revoke@example.com",
        username: "terminal_revoke",
        password: "password123"
      })

    {:ok, daemon, bootstrap} = Daemons.create(user.id)
    assert {:ok, _, reconnect, credential} = Daemons.exchange_bootstrap(daemon.id, bootstrap)
    assert {:ok, revoked} = Daemons.revoke(daemon)

    assert revoked.daemon.status == "revoked"
    assert {:error, :invalid_credentials} = Daemons.rotate_bootstrap(revoked.daemon)
    assert {:error, :invalid_credentials} = Daemons.exchange_bootstrap(daemon.id, bootstrap)
    assert {:error, :invalid_credentials} = Daemons.revalidate_reconnect(daemon.id, credential.id)
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, reconnect)

    assert Repo.aggregate(
             from(c in DaemonCredential,
               where: c.daemon_id == ^daemon.id and c.status == "active"
             ),
             :count
           ) == 0
  end

  defp refute_token_material(result, tokens) do
    inspected = inspect(result)
    refute Enum.any?(tokens, &String.contains?(inspected, &1))
    true
  end

  test "unregister removes never-enrolled provisioning and retains history" do
    {:ok, user} =
      Users.insert(%{
        email: "unregister-pending@example.com",
        username: "unregister_pending",
        password: "password123"
      })

    {:ok, daemon, bootstrap} = Daemons.create(user.id, %{name: "retire me"})

    assert {:ok, %{daemon: removed, invalidated_credential_ids: ids} = result} =
             Daemons.unregister(daemon)

    assert removed.id == daemon.id
    assert removed.status == "removed"
    assert removed.removed_at
    assert removed.name == "retire me"
    assert refute_token_material(result, [bootstrap])
    assert length(ids) == 1

    # Soft tombstone: row, credential audit and history preserved.
    assert Repo.get!(Daemon, daemon.id).status == "removed"

    assert Repo.aggregate(
             from(c in DaemonCredential,
               where: c.daemon_id == ^daemon.id and c.status == "revoked"
             ),
             :count
           ) == 1

    refute Enum.any?(Daemons.list_active_fleet(user.id), &(&1.id == daemon.id))

    # Idempotent retry.
    assert {:ok, %{daemon: again, invalidated_credential_ids: []}} = Daemons.unregister(daemon)
    assert again.status == "removed"

    # Terminal: no credential operation or stale refresh resurrects it.
    assert {:error, :invalid_credentials} = Daemons.exchange_bootstrap(daemon.id, bootstrap)
    assert {:error, :invalid_credentials} = Daemons.rotate_bootstrap(Repo.get!(Daemon, daemon.id))
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, bootstrap)
  end

  test "unregister refuses enrolled identities with ownership_unknown" do
    {:ok, user} =
      Users.insert(%{
        email: "unregister-enrolled@example.com",
        username: "unregister_enrolled",
        password: "password123"
      })

    {:ok, daemon, bootstrap} = Daemons.create(user.id)
    assert {:ok, _, _reconnect, _} = Daemons.exchange_bootstrap(daemon.id, bootstrap)

    assert {:error, :ownership_unknown} = Daemons.unregister(daemon)

    daemon = Repo.get!(Daemon, daemon.id)
    assert daemon.status == "active"
    assert daemon.removed_at == nil

    assert Repo.aggregate(
             from(c in DaemonCredential,
               where:
                 c.daemon_id == ^daemon.id and c.status == "active" and
                   c.credential_kind == "reconnect"
             ),
             :count
           ) == 1

    # Revoked enrolled identities are still conservatively blocked.
    assert {:ok, _} = Daemons.revoke(daemon)
    assert {:error, :ownership_unknown} = Daemons.unregister(daemon)
    assert Repo.get!(Daemon, daemon.id).status == "revoked"
  end

  test "unregister removes revoked never-enrolled provisioning" do
    {:ok, user} =
      Users.insert(%{
        email: "unregister-revoked@example.com",
        username: "unregister_revoked",
        password: "password123"
      })

    {:ok, daemon, _bootstrap} = Daemons.create(user.id)
    assert {:ok, _} = Daemons.revoke(daemon)
    assert {:ok, %{daemon: removed}} = Daemons.unregister(daemon)
    assert removed.status == "removed"
    assert Repo.get!(Daemon, daemon.id).status == "removed"
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

  test "enrollment_metadata projects safe credential summaries without token material" do
    {:ok, user} =
      Users.insert(%{
        email: "metadata-daemon@example.com",
        username: "metadata_daemon",
        password: "password123"
      })

    {:ok, daemon, bootstrap, _credential} = Daemons.create_bootstrap(user.id, %{name: "meta-box"})
    assert {:ok, daemon, reconnect, _} = Daemons.exchange_bootstrap(daemon.id, bootstrap)

    metadata = Daemons.enrollment_metadata(daemon)
    assert metadata.daemon_id == daemon.id
    assert metadata.status == "active"
    assert metadata.enrolled_at == daemon.enrolled_at

    assert [bootstrap_meta, reconnect_meta] = metadata.credentials
    assert bootstrap_meta.credential_kind == "bootstrap"
    assert bootstrap_meta.consumed_at
    assert reconnect_meta.credential_kind == "reconnect"
    assert reconnect_meta.status == "active"
    assert reconnect_meta.expires_at

    projected = Map.keys(bootstrap_meta) ++ Map.keys(reconnect_meta)
    refute :token_hash in projected
    refute :daemon_id in projected
    refute inspect(metadata) =~ reconnect
  end
end
