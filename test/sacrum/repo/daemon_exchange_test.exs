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

  defp access(daemon_id, token, opts \\ []) do
    case Daemons.authenticate_access(daemon_id, token, opts) do
      {:ok, %{daemon: daemon}} -> {:ok, daemon}
      error -> error
    end
  end

  test "exchange preserves owner and identity, issues only SHA-256 hashes and refuses replay",
       ctx do
    now = DateTime.utc_now()

    assert {:ok, daemon, pair} =
             Accounts.Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap, now: now)

    assert daemon.id == ctx.daemon.id
    assert daemon.user_id == ctx.owner.id
    assert pair.access_expires_at == DateTime.add(now, 3_600)
    assert pair.refresh_expires_at == DateTime.add(now, 2_592_000)

    for {kind, token} <- [access: pair.access_token, refresh: pair.refresh_token] do
      credential =
        Repo.one!(
          from c in DaemonCredential,
            where: c.daemon_id == ^daemon.id and c.credential_kind == ^to_string(kind)
        )

      assert credential.token_hash == DaemonCredential.hash_token(token)
      refute String.starts_with?(credential.token_hash, "$argon2")
    end

    bootstrap =
      Repo.one!(
        from c in DaemonCredential,
          where: c.daemon_id == ^daemon.id and c.credential_kind == "bootstrap"
      )

    assert bootstrap.consumed_at == now
    assert bootstrap.token_hash == DaemonCredential.hash_token(ctx.bootstrap)
    assert {:ok, %{id: id}} = access(daemon.id, pair.access_token, now: now)
    assert id == daemon.id
    assert {:error, :invalid_credentials} = access(daemon.id, ctx.bootstrap)
    assert {:error, :invalid_credentials} = access(daemon.id, pair.refresh_token)
    assert {:error, :invalid_credentials} = Daemons.exchange_bootstrap(daemon.id, ctx.bootstrap)

    assert Repo.aggregate(from(c in DaemonCredential, where: c.daemon_id == ^daemon.id), :count) ==
             3
  end

  test "bootstrap expiry boundary is exclusive and access has independent expiry", ctx do
    bootstrap = Repo.one!(from c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id)

    assert abs(DateTime.diff(bootstrap.expires_at, bootstrap.inserted_at)) in 86_399..86_401

    assert {:error, :invalid_credentials} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap, now: bootstrap.expires_at)

    assert {:error, :invalid_credentials} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap,
               now: DateTime.add(bootstrap.expires_at, 1)
             )

    now = DateTime.add(bootstrap.expires_at, -1, :microsecond)

    assert {:ok, daemon, pair} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap, now: now)

    assert {:ok, _} = access(daemon.id, pair.access_token, now: bootstrap.expires_at)

    assert {:error, :invalid_credentials} =
             access(daemon.id, pair.access_token, now: pair.access_expires_at)
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
      assert {:error, :invalid_credentials} = Daemons.authenticate_access(id, token)
      assert {:error, :invalid_credentials} = Daemons.refresh(id, token)
    end

    bootstrap = Repo.one!(from c in DaemonCredential, where: c.daemon_id == ^ctx.daemon.id)
    Repo.update!(DaemonCredential.revoke_changeset(bootstrap))

    assert {:error, :invalid_credentials} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
  end

  test "deleted daemon refuses exchange, access and refresh", ctx do
    assert {:ok, _, pair} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
    assert {:ok, deleted} = Accounts.Daemons.unregister(ctx.owner.id, ctx.daemon.id)
    assert {:error, :invalid_credentials} = access(deleted.id, pair.access_token)
    assert {:error, :invalid_credentials} = Daemons.refresh(deleted.id, pair.refresh_token)
    assert {:error, :invalid_credentials} = Daemons.rotate(deleted)
    assert {:error, :not_found} = Accounts.Daemons.rotate(ctx.owner.id, ctx.daemon.id)

    {:ok, another, bootstrap} = Daemons.create(ctx.owner.id)
    {:ok, _} = Daemons.unregister(another)
    assert {:error, :invalid_credentials} = Daemons.exchange_bootstrap(another.id, bootstrap)
  end

  test "lost response recovery requires owner reissue and invalidates the lost pair", ctx do
    assert {:ok, _, lost} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)

    assert {:error, :invalid_credentials} =
             Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)

    assert {:error, :not_found} = Accounts.Daemons.rotate(Ecto.UUID.generate(), ctx.daemon.id)
    assert {:ok, daemon, new_bootstrap} = Accounts.Daemons.rotate(ctx.owner.id, ctx.daemon.id)
    assert daemon.id == ctx.daemon.id
    assert {:error, :invalid_credentials} = access(daemon.id, lost.access_token)
    assert {:error, :invalid_credentials} = Daemons.refresh(daemon.id, lost.refresh_token)
    assert {:error, :invalid_credentials} = access(daemon.id, new_bootstrap)
    assert {:ok, _, recovered} = Daemons.exchange_bootstrap(daemon.id, new_bootstrap)
    assert {:ok, _} = access(daemon.id, recovered.access_token)

    assert Repo.aggregate(
             from(c in DaemonCredential,
               where:
                 c.daemon_id == ^daemon.id and c.status == "active" and
                   c.credential_kind in ["access", "refresh"]
             ),
             :count
           ) == 2
  end

  describe "refresh" do
    setup ctx do
      {:ok, _, pair} = Daemons.exchange_bootstrap(ctx.daemon.id, ctx.bootstrap)
      %{pair: pair}
    end

    test "rotates the pair, revokes earlier access tokens and rejects wrong-kind tokens", ctx do
      id = ctx.daemon.id

      assert {:error, :invalid_credentials} = Daemons.refresh(id, ctx.pair.access_token)
      assert {:error, :invalid_credentials} = Daemons.refresh(id, ctx.bootstrap)

      assert {:ok, _, next} = Daemons.refresh(id, ctx.pair.refresh_token)
      assert next.refresh_token != ctx.pair.refresh_token
      assert {:error, :invalid_credentials} = access(id, ctx.pair.access_token)
      assert {:ok, _} = access(id, next.access_token)
      assert {:error, :invalid_credentials} = access(id, next.refresh_token)
    end

    test "an expired refresh token cannot refresh", ctx do
      assert {:error, :invalid_credentials} =
               Daemons.refresh(ctx.daemon.id, ctx.pair.refresh_token,
                 now: ctx.pair.refresh_expires_at
               )
    end

    test "a refresh token is rotated once its successor is first used", ctx do
      id = ctx.daemon.id
      {:ok, _, next} = Daemons.refresh(id, ctx.pair.refresh_token)

      # Before the successor is used the predecessor is still valid (lost response).
      assert {:ok, _} = Daemons.authenticate_access(id, next.access_token)
      assert {:error, :invalid_credentials} = Daemons.refresh(id, ctx.pair.refresh_token)
      assert {:ok, _, _} = Daemons.refresh(id, next.refresh_token)
    end

    test "re-presenting the predecessor before use recovers and revokes the unused successor",
         ctx do
      id = ctx.daemon.id
      {:ok, _, lost} = Daemons.refresh(id, ctx.pair.refresh_token)
      assert {:ok, _, recovered} = Daemons.refresh(id, ctx.pair.refresh_token)

      assert {:error, :invalid_credentials} = access(id, lost.access_token)
      assert {:error, :invalid_credentials} = Daemons.refresh(id, lost.refresh_token)
      assert {:ok, _} = access(id, recovered.access_token)

      # Using the recovered successor retires the original predecessor.
      assert {:error, :invalid_credentials} = Daemons.refresh(id, ctx.pair.refresh_token)
      assert {:ok, _, _} = Daemons.refresh(id, recovered.refresh_token)
    end

    test "owner rotation and deletion invalidate access and refresh tokens", ctx do
      {:ok, _, _new_bootstrap} = Accounts.Daemons.rotate(ctx.owner.id, ctx.daemon.id)
      assert {:error, :invalid_credentials} = access(ctx.daemon.id, ctx.pair.access_token)

      assert {:error, :invalid_credentials} =
               Daemons.refresh(ctx.daemon.id, ctx.pair.refresh_token)
    end
  end
end
