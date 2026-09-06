defmodule Sacrum.Repo.Schemas.DaemonCredentialTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.DaemonCredential

  test "requires daemon, hash, and expiry" do
    assert %{
             daemon_id: ["can't be blank"],
             token_hash: ["can't be blank"],
             expires_at: ["can't be blank"]
           } =
             errors_on(DaemonCredential.create_changeset(%DaemonCredential{}, %{}))
  end

  test "rejects invalid status and short hashes" do
    changeset =
      DaemonCredential.create_changeset(
        %DaemonCredential{daemon_id: Ecto.UUID.generate()},
        %{token_hash: "short", expires_at: DateTime.utc_now(), status: "unknown"}
      )

    errors = errors_on(changeset)
    assert %{token_hash: [_], status: [_]} = errors
  end

  test "accepts bootstrap and reconnect kinds while rejecting unknown kinds" do
    for kind <- ["bootstrap", "reconnect"] do
      changeset =
        DaemonCredential.create_changeset(
          %DaemonCredential{daemon_id: Ecto.UUID.generate(), credential_kind: kind},
          %{token_hash: String.duplicate("a", 32), expires_at: DateTime.utc_now()}
        )

      assert changeset.valid?
    end

    refute DaemonCredential.create_changeset(
             %DaemonCredential{daemon_id: Ecto.UUID.generate(), credential_kind: "other"},
             %{token_hash: String.duplicate("a", 32), expires_at: DateTime.utc_now()}
           ).valid?
  end

  test "bootstrap consumability is independent from reconnect validity" do
    now = DateTime.utc_now()

    bootstrap = %DaemonCredential{
      credential_kind: "bootstrap",
      status: "active",
      expires_at: DateTime.add(now, 60, :second)
    }

    reconnect = %DaemonCredential{
      credential_kind: "reconnect",
      status: "active",
      expires_at: DateTime.add(now, -1, :second)
    }

    assert DaemonCredential.consumable?(bootstrap, now)
    refute DaemonCredential.consumable?(%{bootstrap | consumed_at: now}, now)
    refute DaemonCredential.consumable?(reconnect, now)
  end

  test "consumption is bootstrap-only and one-time" do
    now = DateTime.utc_now()

    bootstrap = %DaemonCredential{
      credential_kind: "bootstrap",
      status: "active",
      expires_at: DateTime.add(now, 60, :second)
    }

    assert DaemonCredential.consume_changeset(bootstrap).valid?

    consumed = %{bootstrap | consumed_at: now}
    refute DaemonCredential.consume_changeset(consumed).valid?

    reconnect = %DaemonCredential{
      credential_kind: "reconnect",
      status: "active",
      expires_at: DateTime.add(now, 60, :second)
    }

    refute DaemonCredential.consume_changeset(reconnect).valid?
    refute DaemonCredential.consume_changeset(%{bootstrap | expires_at: now}).valid?
    refute DaemonCredential.consume_changeset(%{bootstrap | status: "revoked"}).valid?
    refute DaemonCredential.consume_changeset(%{bootstrap | revoked_at: now}).valid?

    consumption = DaemonCredential.consume_changeset(bootstrap, now)
    assert consumption.valid?
    assert Ecto.Changeset.get_field(consumption, :consumed_at) == now
    refute DaemonCredential.consume_changeset(bootstrap, bootstrap.expires_at).valid?
  end

  test "authentication validity rejects consumed, revoked, and expired credentials" do
    now = DateTime.utc_now()
    base = %DaemonCredential{status: "active", expires_at: DateTime.add(now, 60, :second)}

    assert DaemonCredential.valid_for_authentication?(%{base | credential_kind: "bootstrap"}, now)
    assert DaemonCredential.valid_for_authentication?(%{base | credential_kind: "reconnect"}, now)
    refute DaemonCredential.valid_for_authentication?(%{base | consumed_at: now}, now)
    refute DaemonCredential.valid_for_authentication?(%{base | status: "revoked"}, now)
    refute DaemonCredential.valid_for_authentication?(%{base | expires_at: now}, now)
  end

  test "generic JSON serialization never exposes the persisted hash" do
    credential = %DaemonCredential{
      id: Ecto.UUID.generate(),
      daemon_id: Ecto.UUID.generate(),
      token_hash: "stored-hash",
      credential_kind: "reconnect",
      status: "active",
      expires_at: DateTime.utc_now()
    }

    encoded = Jason.encode!(credential)

    refute encoded =~ "stored-hash"
    refute encoded =~ "token_hash"
    assert encoded =~ "credential_kind"
  end

  test "ignores untrusted identity, kind, consumption and revocation attributes" do
    daemon_id = Ecto.UUID.generate()

    changeset =
      DaemonCredential.create_changeset(
        %DaemonCredential{daemon_id: daemon_id, credential_kind: "bootstrap"},
        %{
          daemon_id: Ecto.UUID.generate(),
          credential_kind: "reconnect",
          consumed_at: DateTime.utc_now(),
          revoked_at: DateTime.utc_now(),
          token_hash: String.duplicate("a", 32),
          expires_at: DateTime.utc_now()
        }
      )

    assert {:ok, credential} = apply_action(changeset, :insert)
    assert credential.daemon_id == daemon_id
    assert credential.credential_kind == "bootstrap"
    assert credential.consumed_at == nil
    assert credential.revoked_at == nil
  end

  test "returns a changeset error for an invalid daemon reference" do
    changeset =
      DaemonCredential.create_changeset(
        %DaemonCredential{daemon_id: Ecto.UUID.generate()},
        %{token_hash: String.duplicate("a", 32), expires_at: DateTime.utc_now()}
      )

    assert {:error, invalid} = Sacrum.Repo.insert(changeset)
    assert errors_on(invalid).daemon_id == ["does not exist"]
  end

  test "database defaults preserve legacy expiry and revocation without granting bootstrap privileges" do
    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "legacy@example.com",
        username: "legacy",
        password: "password123"
      })

    {:ok, daemon} = Sacrum.Repo.insert(%Sacrum.Repo.Schemas.Daemon{user_id: user.id})
    now = DateTime.utc_now()

    for {status, expires_at, revoked_at} <- [
          {"active", DateTime.add(now, 60), nil},
          {"active", DateTime.add(now, -60), nil},
          {"revoked", DateTime.add(now, 60), now}
        ] do
      id = Ecto.UUID.generate()
      # Omit the newly introduced columns just as the legacy application does.
      {1, _} =
        Sacrum.Repo.insert_all("daemon_credentials", [
          %{
            id: Ecto.UUID.dump!(id),
            daemon_id: Ecto.UUID.dump!(daemon.id),
            token_hash: Ecto.UUID.generate(),
            status: status,
            expires_at: expires_at,
            revoked_at: revoked_at,
            inserted_at: now,
            updated_at: now
          }
        ])

      row = Sacrum.Repo.get!(DaemonCredential, id)
      assert row.credential_kind == "reconnect"
      assert row.consumed_at == nil
      assert row.expires_at == expires_at
      assert row.revoked_at == revoked_at
      assert row.status == status
      refute DaemonCredential.consumable?(row, now)

      assert DaemonCredential.valid_for_authentication?(row, now) ==
               (status == "active" and DateTime.compare(expires_at, now) == :gt)
    end
  end

  test "database rejects inconsistent credential states" do
    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "constraints@example.com",
        username: "constraints",
        password: "password123"
      })

    {:ok, daemon} = Sacrum.Repo.insert(%Sacrum.Repo.Schemas.Daemon{user_id: user.id})

    for {field, value, constraint} <- [
          {:credential_kind, "unknown", :daemon_credentials_credential_kind_check},
          {:status, "unknown", :daemon_credentials_status_check},
          {:revoked_at, DateTime.utc_now(), :daemon_credentials_revoked_at_check},
          {:consumed_at, DateTime.utc_now(), :daemon_credentials_consumed_at_check}
        ] do
      changeset =
        %DaemonCredential{
          daemon_id: daemon.id,
          token_hash: Ecto.UUID.generate(),
          expires_at: DateTime.utc_now()
        }
        |> change(%{field => value})
        |> check_constraint(field, name: constraint)

      assert {:error, invalid} = Sacrum.Repo.insert(changeset, mode: :savepoint)
      assert errors_on(invalid)[field] == ["is invalid"]
    end
  end

  test "one live bootstrap per daemon; revoked or consumed rows do not block replacement" do
    {:ok, user} =
      Sacrum.Repo.Users.insert(%{
        email: "live-bootstrap@example.com",
        username: "livebootstrap",
        password: "password123"
      })

    {:ok, daemon} = Sacrum.Repo.insert(%Sacrum.Repo.Schemas.Daemon{user_id: user.id})
    expires_at = DateTime.add(DateTime.utc_now(), 60, :second)

    {:ok, first} =
      %DaemonCredential{daemon_id: daemon.id, credential_kind: "bootstrap"}
      |> DaemonCredential.create_changeset(%{
        token_hash: String.duplicate("a", 32),
        expires_at: expires_at
      })
      |> Sacrum.Repo.insert()

    assert {:error, invalid} =
             %DaemonCredential{daemon_id: daemon.id, credential_kind: "bootstrap"}
             |> DaemonCredential.create_changeset(%{
               token_hash: String.duplicate("b", 32),
               expires_at: expires_at
             })
             |> Sacrum.Repo.insert(mode: :savepoint)

    assert errors_on(invalid).daemon_id == ["has already been taken"]

    {:ok, _} = first |> DaemonCredential.revoke_changeset() |> Sacrum.Repo.update()

    {:ok, replacement} =
      %DaemonCredential{daemon_id: daemon.id, credential_kind: "bootstrap"}
      |> DaemonCredential.create_changeset(%{
        token_hash: String.duplicate("c", 32),
        expires_at: expires_at
      })
      |> Sacrum.Repo.insert()

    {:ok, _} = replacement |> DaemonCredential.consume_changeset() |> Sacrum.Repo.update()

    assert {:ok, _} =
             %DaemonCredential{daemon_id: daemon.id, credential_kind: "bootstrap"}
             |> DaemonCredential.create_changeset(%{
               token_hash: String.duplicate("d", 32),
               expires_at: expires_at
             })
             |> Sacrum.Repo.insert()
  end
end
