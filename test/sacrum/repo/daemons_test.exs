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

    {:ok, rotated, new_bootstrap, _} = Daemons.rotate_bootstrap(daemon)
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
