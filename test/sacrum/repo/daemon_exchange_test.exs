defmodule Sacrum.Repo.DaemonExchangeTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts
  alias Sacrum.Repo.{Daemons, Users}
  alias Sacrum.Repo.Schemas.DaemonCredential

  setup do
    {:ok, owner} =
      Users.insert(%{
        email: "exchange@example.com",
        username: "exchange",
        password: "password123"
      })

    {:ok, daemon, bootstrap} = Accounts.Daemons.create(owner.id)
    %{owner: owner, daemon: daemon, bootstrap: bootstrap}
  end

  test "exchange preserves owner and identity, issues only hashes and refuses replay", ctx do
    now = DateTime.utc_now()

    assert {:ok, daemon, reconnect, credential} =
             Accounts.Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap, now: now)

    assert daemon.id == ctx.daemon.id
    assert daemon.user_id == ctx.owner.id
    assert credential.daemon_id == daemon.id
    assert credential.credential_kind == "reconnect"
    assert credential.expires_at == DateTime.add(now, 2_592_000)
    refute credential.token_hash == reconnect
    assert Argon2.verify_pass(reconnect, credential.token_hash)
    assert {:ok, ^daemon} = Daemons.verify_token(daemon.id, reconnect, now: now)
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, ctx.bootstrap)
    assert {:error, :invalid_credentials} = Daemons.exchange_bootstrap(daemon.id, ctx.bootstrap)

    assert Repo.aggregate(from(c in DaemonCredential, where: c.daemon_id == ^daemon.id), :count) ==
             2
  end

  test "bootstrap expiry boundary is exclusive and reconnect has independent expiry", ctx do
    bootstrap = Repo.one!(from c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id)

    assert {:error, :invalid_credentials} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap, now: bootstrap.expires_at)

    assert {:error, :invalid_credentials} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap,
               now: DateTime.add(bootstrap.expires_at, 1)
             )

    assert {:ok, daemon, reconnect, credential} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap,
               now: DateTime.add(bootstrap.expires_at, -1, :microsecond)
             )

    assert {:ok, _} = Daemons.verify_token(daemon.id, reconnect, now: bootstrap.expires_at)

    assert {:error, :invalid_credentials} =
             Daemons.verify_token(daemon.id, reconnect, now: credential.expires_at)
  end

  test "malformed input, wrong daemon pairing and revoked credentials fail closed", ctx do
    {:ok, other, _} = Daemons.create(ctx.owner.id)

    for {id, token} <- [
          {nil, ctx.bootstrap},
          {"malformed", ctx.bootstrap},
          {ctx.daemon.id, nil},
          {ctx.daemon.id, %{}},
          {other.id, ctx.bootstrap}
        ] do
      assert {:error, :invalid_credentials} = Daemons.exchange_bootstrap(id, token)
      assert {:error, :invalid_credentials} = Daemons.verify_token(id, token)
    end

    bootstrap = Repo.one!(from c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id)
    Repo.update!(DaemonCredential.revoke_changeset(bootstrap))

    assert {:error, :invalid_credentials} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
  end

  test "revoked daemon refuses exchange and reconnect authentication", ctx do
    assert {:ok, _, reconnect, _} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
    assert {:ok, revoked} = Accounts.Daemons.revoke(ctx.owner.id, ctx.daemon.id)
    assert {:error, :invalid_credentials} = Daemons.verify_token(revoked.id, reconnect)
    assert {:error, :invalid_credentials} = Daemons.rotate(revoked)

    {:ok, another, bootstrap} = Daemons.create(ctx.owner.id)
    {:ok, _} = Daemons.revoke(another)
    assert {:error, :invalid_credentials} = Daemons.exchange_bootstrap(another.id, bootstrap)
  end

  test "lost response recovery requires owner reissue and invalidates the lost reconnect", ctx do
    assert {:ok, _, lost_reconnect, _} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)

    assert {:error, :invalid_credentials} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)

    assert {:error, :not_found} = Accounts.Daemons.rotate(Ecto.UUID.generate(), ctx.daemon.id)
    assert {:ok, daemon, new_bootstrap} = Accounts.Daemons.rotate(ctx.owner.id, ctx.daemon.id)
    assert daemon.id == ctx.daemon.id
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, lost_reconnect)
    assert {:error, :invalid_credentials} = Daemons.verify_token(daemon.id, new_bootstrap)
    assert {:ok, _, recovered, _} = Daemons.exchange_bootstrap(daemon.id, new_bootstrap)
    assert {:ok, _} = Daemons.verify_token(daemon.id, recovered)

    assert Repo.aggregate(
             from(c in DaemonCredential,
               where:
                 c.daemon_id == ^daemon.id and c.status == "active" and
                   c.credential_kind == "reconnect"
             ),
             :count
           ) == 1
  end
end
