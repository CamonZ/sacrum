defmodule Sacrum.Repo.Daemons do
  @moduledoc "Database operations for daemon provisioning and credentials."

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Daemon

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{Daemon, DaemonCredential, User}

  @token_bytes 32
  # Registration (bootstrap) token: 24h, one-time.
  @default_ttl 86_400
  # Access token: 1h. Refresh token: 30 days.
  @access_ttl_seconds 3_600
  @refresh_ttl_seconds 2_592_000

  @typedoc "A freshly issued access/refresh pair; plaintext is only available here."
  @type token_pair :: %{
          access_token: String.t(),
          access_expires_at: DateTime.t(),
          refresh_token: String.t(),
          refresh_expires_at: DateTime.t()
        }

  @typedoc "An authenticated access credential with its daemon and owning user."
  @type access_principal :: %{
          daemon: Daemon.t(),
          credential: DaemonCredential.t(),
          user: User.t()
        }

  @typedoc """
  Committed lifecycle mutation result. Token/credential are present only for
  owner-authorized issuance (rotate/create). Post-commit session invalidation
  is always by daemon id — the registry holds at most one session per daemon.
  """
  @type committed_lifecycle :: %{
          daemon: Daemon.t(),
          credential: DaemonCredential.t() | nil,
          token: String.t() | nil
        }

  @spec create(User.t() | String.t() | Daemon.t()) ::
          {:ok, Daemon.t(), String.t()} | {:error, Ecto.Changeset.t()}
  @spec create(User.t() | String.t() | Daemon.t(), map()) ::
          {:ok, Daemon.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create(user_or_daemon, attrs \\ %{}) do
    case create_bootstrap(user_or_daemon, attrs) do
      {:ok, daemon, token, _credential} -> {:ok, daemon, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_bootstrap(User.t() | String.t() | Daemon.t(), map(), keyword()) ::
          {:ok, Daemon.t(), String.t(), DaemonCredential.t()} | {:error, Ecto.Changeset.t()}
  def create_bootstrap(user_or_daemon, attrs \\ %{}, opts \\ [])

  def create_bootstrap(%User{id: user_id}, attrs, opts),
    do: create_bootstrap(%Daemon{user_id: user_id}, attrs, opts)

  def create_bootstrap(%Daemon{} = daemon, attrs, opts) do
    token = new_token()
    token_hash = DaemonCredential.hash_token(token)
    now = now(opts)
    expires_at = DateTime.add(now, Map.get(attrs, :ttl, @default_ttl), :second)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:daemon, Daemon.create_changeset(daemon, attrs))
      |> Ecto.Multi.insert(:credential, fn %{daemon: daemon} ->
        DaemonCredential.create_changeset(
          %DaemonCredential{daemon_id: daemon.id, credential_kind: "bootstrap"},
          %{
            token_hash: token_hash,
            expires_at: expires_at
          }
        )
      end)

    case Repo.transaction(multi) do
      {:ok, %{daemon: daemon, credential: credential}} -> {:ok, daemon, token, credential}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def create_bootstrap(user_id, attrs, opts) when is_binary(user_id),
    do: create_bootstrap(%Daemon{user_id: user_id}, attrs, opts)

  @doc """
  Unregisters a daemon by deleting it under its row lock and transaction.

  The lock is shared with bootstrap exchange and credential rotation, so a
  committed delete always wins over any credentials issued by a contending
  lifecycle operation. The daemon foreign key owns credential cleanup through
  `ON DELETE CASCADE`; no credential rows are retained or manually revoked.

  Callers that have an authoritative daemon-keyed work guard can pass an
  `active_work?` function. A connected session alone is not a database work
  reference: successful unregister invalidates it after commit.
  """
  @spec unregister(Daemon.t()) ::
          {:ok, committed_lifecycle()}
          | {:error, :not_found | :active_work | Ecto.Changeset.t()}
  @spec unregister(Daemon.t(), keyword()) ::
          {:ok, committed_lifecycle()}
          | {:error, :not_found | :active_work | Ecto.Changeset.t()}
  def unregister(%Daemon{} = daemon), do: unregister(daemon, [])

  def unregister(%Daemon{} = daemon, opts) when is_list(opts) do
    Repo.transaction(fn ->
      daemon = lock_daemon_for_delete!(daemon.id)

      if active_work?(opts, daemon), do: Repo.rollback(:active_work)

      delete_locked!(daemon)
    end)
  end

  defp delete_locked!(%Daemon{} = daemon) do
    case Repo.delete(daemon) do
      {:ok, deleted} -> lifecycle_result(deleted)
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp active_work?(opts, daemon) do
    case Keyword.get(opts, :active_work?) do
      fun when is_function(fun, 1) -> fun.(daemon)
      _ -> false
    end
  end

  @doc "Owner's active daemon identities. Deleted rows are not returned."
  @spec list_active_fleet(String.t()) :: [Daemon.t()]
  def list_active_fleet(user_id) when is_binary(user_id) do
    Repo.all(
      from d in Daemon,
        where: d.user_id == ^user_id,
        order_by: [asc: d.inserted_at, asc: d.id]
    )
  end

  @doc "Renames or clears the display name under the daemon row lock."
  @spec rename(Daemon.t(), map()) ::
          {:ok, Daemon.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename(%Daemon{} = daemon, attrs) do
    Repo.transaction(fn ->
      daemon.id
      |> lock_daemon_row!()
      |> apply_rename!(attrs)
    end)
  end

  defp apply_rename!(%Daemon{} = daemon, attrs) do
    case Repo.update(Daemon.name_changeset(daemon, attrs)) do
      {:ok, renamed} -> renamed
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "Updates the daemon concurrency limit under the daemon row lock."
  @spec update_max_concurrency(Daemon.t(), pos_integer() | nil) ::
          {:ok, Daemon.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_max_concurrency(%Daemon{} = daemon, max_concurrency) do
    Repo.transaction(fn ->
      daemon.id
      |> lock_daemon_row!()
      |> apply_max_concurrency!(max_concurrency)
    end)
  end

  defp apply_max_concurrency!(%Daemon{} = daemon, max_concurrency) do
    case Repo.update(
           Daemon.max_concurrency_changeset(daemon, %{max_concurrency: max_concurrency})
         ) do
      {:ok, updated} -> updated
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  @doc "Enrollment metadata without token hashes or plaintext."
  @spec enrollment_metadata(Daemon.t()) :: %{
          daemon_id: String.t(),
          status: String.t(),
          enrolled_at: DateTime.t() | nil,
          credentials: [map()]
        }
  def enrollment_metadata(%Daemon{} = daemon) do
    credentials =
      Repo.all(
        from c in DaemonCredential,
          where: c.daemon_id == ^daemon.id,
          order_by: [asc: c.inserted_at, asc: c.id]
      )

    %{
      daemon_id: daemon.id,
      status: daemon.status,
      enrolled_at: daemon.enrolled_at,
      credentials: Enum.map(credentials, &DaemonCredential.safe_metadata/1)
    }
  end

  @doc """
  Row-locked rotation: revoke live credentials and issue a fresh bootstrap
  on the same identity. Deletion is the separate identity-invalidating
  operation.
  """
  @spec rotate(Daemon.t()) ::
          {:ok, committed_lifecycle()}
          | {:error, :invalid_credentials | Ecto.Changeset.t()}
  @spec rotate(Daemon.t(), keyword()) ::
          {:ok, committed_lifecycle()}
          | {:error, :invalid_credentials | Ecto.Changeset.t()}
  def rotate(%Daemon{} = daemon, opts \\ []) do
    case rotate_bootstrap(daemon, opts) do
      {:ok, result} -> {:ok, %{result | token: nil, credential: nil}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Same as `rotate/1` with the new bootstrap token for the owner response."
  @spec rotate_bootstrap(Daemon.t()) ::
          {:ok, committed_lifecycle()}
          | {:error, :invalid_credentials | Ecto.Changeset.t()}
  @spec rotate_bootstrap(Daemon.t(), keyword()) ::
          {:ok, committed_lifecycle()}
          | {:error, :invalid_credentials | Ecto.Changeset.t()}
  def rotate_bootstrap(%Daemon{} = daemon, opts \\ []) do
    now = now(opts)
    token = new_token()
    token_hash = DaemonCredential.hash_token(token)

    Repo.transaction(fn ->
      daemon = lock_daemon_row!(daemon.id)

      unless Daemon.credential_eligible?(daemon) do
        Repo.rollback(:invalid_credentials)
      end

      invalidate_active_credentials(daemon.id, now)

      credential =
        insert_credential!(daemon.id, "bootstrap", token_hash, DateTime.add(now, @default_ttl))

      %{daemon: daemon, credential: credential, token: token}
    end)
  end

  @doc """
  Exchanges a registration (bootstrap) token exactly once, returning the daemon
  and a fresh access/refresh pair. Only the successful response contains the
  plaintext. A lost response requires owner-authorized rotation and a new exchange.

  The optional `:now` DateTime is a deterministic clock seam for trusted callers.
  """
  @spec exchange_bootstrap(term(), term(), keyword()) ::
          {:ok, Daemon.t(), token_pair()}
          | {:error, :invalid_credentials | :unavailable | Ecto.Changeset.t()}
  def exchange_bootstrap(daemon_id, token, opts \\ [])

  def exchange_bootstrap(daemon_id, token, opts) when is_binary(daemon_id) and is_binary(token) do
    transact_credential(daemon_id, "bootstrap", token, opts, fn daemon, bootstrap, now ->
      if DaemonCredential.consumable?(bootstrap, now) do
        Repo.update!(DaemonCredential.consume_changeset(bootstrap, now))
        {pair, _refresh} = issue_pair!(daemon.id, now, nil)
        {record_enrollment!(daemon, now), pair}
      else
        Repo.rollback(:invalid_credentials)
      end
    end)
  end

  def exchange_bootstrap(_, _, _), do: {:error, :invalid_credentials}

  @doc """
  Authenticates an access token with a single SHA-256 indexed SELECT.

  No transaction, row lock or Argon2 runs here. The daemon and owning user are
  loaded by the same statement. The first use of an access token issued by a
  refresh additionally retires the predecessor refresh token with one
  idempotent UPDATE, outside any transaction.
  """
  @spec authenticate_access(term(), term(), keyword()) ::
          {:ok, access_principal()} | {:error, :invalid_credentials | :unavailable}
  def authenticate_access(daemon_id, token, opts \\ [])

  def authenticate_access(daemon_id, token, opts)
      when is_binary(daemon_id) and is_binary(token) do
    with {:ok, daemon_id} <- Ecto.UUID.cast(daemon_id),
         {daemon, credential, user, stale_predecessor_id} <-
           fetch_access(daemon_id, DaemonCredential.hash_token(token)),
         true <- Daemon.credential_eligible?(daemon),
         true <- DaemonCredential.valid_for_authentication?(credential, now(opts)) do
      retire_predecessor(stale_predecessor_id, now(opts))
      {:ok, %{daemon: daemon, credential: credential, user: user}}
    else
      _ -> {:error, :invalid_credentials}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  def authenticate_access(_, _, _), do: {:error, :invalid_credentials}

  # One SELECT: access credential, daemon, owner, and the still-active
  # predecessor refresh token (if the pair's refresh has not yet retired it).
  defp fetch_access(daemon_id, hash) do
    Repo.one(
      from c in DaemonCredential,
        join: d in Daemon,
        on: d.id == c.daemon_id,
        join: u in User,
        on: u.id == d.user_id,
        left_join: r in DaemonCredential,
        on: r.id == c.predecessor_id,
        left_join: p in DaemonCredential,
        on: p.id == r.predecessor_id and p.status == "active",
        where:
          c.daemon_id == ^daemon_id and c.token_hash == ^hash and c.credential_kind == "access",
        select: {d, c, u, p.id}
    )
  end

  defp retire_predecessor(nil, _now), do: :ok

  defp retire_predecessor(predecessor_id, now) do
    # Sockets never authenticate with refresh tokens, so no session is affected.
    Repo.update_all(
      from(c in DaemonCredential,
        where: c.id == ^predecessor_id and c.status == "active"
      ),
      set: [status: "revoked", revoked_at: now, updated_at: now]
    )

    :ok
  end

  @doc """
  Exchanges a refresh token for a new access token and a rotated refresh token.

  This is the only place rotation, revocation and the daemon row lock run:

    * all of the daemon's previous access tokens are revoked immediately;
    * the presented refresh token stays valid until its successor is first used
      (request, socket connect or refresh), so a lost response can be recovered
      by presenting it again, which revokes the unused successor;
    * once the successor is used the presented token simply fails.
  """
  @spec refresh(term(), term(), keyword()) ::
          {:ok, Daemon.t(), token_pair()}
          | {:error, :invalid_credentials | :unavailable | Ecto.Changeset.t()}
  def refresh(daemon_id, token, opts \\ [])

  def refresh(daemon_id, token, opts) when is_binary(daemon_id) and is_binary(token) do
    result =
      transact_credential(daemon_id, "refresh", token, opts, fn daemon, presented, now ->
        if DaemonCredential.valid_for_authentication?(presented, now) do
          rotate_refresh!(daemon, presented, now)
        else
          Repo.rollback(:invalid_credentials)
        end
      end)

    invalidate_sessions_on_success(result)
  end

  def refresh(_, _, _), do: {:error, :invalid_credentials}

  defp invalidate_sessions_on_success({:ok, daemon, _pair} = result) do
    Sacrum.DaemonConnectionRegistry.invalidate_sessions(daemon.id)
    result
  end

  defp invalidate_sessions_on_success(result), do: result

  defp rotate_refresh!(daemon, presented, now) do
    # Every earlier access token dies on refresh, and presenting a
    # predecessor revokes its unused successor refresh token.
    revoke_credentials!(
      from(c in DaemonCredential,
        where:
          c.daemon_id == ^daemon.id and c.status == "active" and
            (c.credential_kind == "access" or
               (c.credential_kind == "refresh" and c.predecessor_id == ^presented.id))
      ),
      now
    )

    # Presenting a successor activates it: its predecessor is retired.
    if presented.predecessor_id do
      revoke_credentials!(
        from(c in DaemonCredential,
          where: c.id == ^presented.predecessor_id and c.status == "active"
        ),
        now
      )
    end

    {pair, _} = issue_pair!(daemon.id, now, presented.id)
    {daemon, pair}
  end

  # Runs `fun` under the daemon row lock with the matching credential row locked.
  # A missing credential rolls back as invalid; `fun` returns `{daemon, pair}`.
  defp transact_credential(daemon_id, kind, token, opts, fun) do
    case Ecto.UUID.cast(daemon_id) do
      {:ok, daemon_id} -> locked_credential_tx(daemon_id, kind, token, opts, fun)
      _ -> {:error, :invalid_credentials}
    end
  rescue
    _ in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  defp locked_credential_tx(daemon_id, kind, token, opts, fun) do
    hash = DaemonCredential.hash_token(token)

    result =
      Repo.transaction(fn ->
        daemon = lock_daemon!(daemon_id)

        credential =
          Repo.one(
            from c in DaemonCredential,
              where:
                c.daemon_id == ^daemon_id and c.token_hash == ^hash and
                  c.credential_kind == ^kind,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:invalid_credentials)

        fun.(daemon, credential, now(opts))
      end)

    case result do
      {:ok, {daemon, pair}} -> {:ok, daemon, pair}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Rechecks an already authenticated access credential by persisted identity."
  @spec revalidate_access(term(), term(), keyword()) ::
          {:ok, Daemon.t(), DaemonCredential.t()} | {:error, :invalid_credentials}
  def revalidate_access(daemon_id, credential_id, opts \\ []) do
    with {:ok, daemon_id} <- Ecto.UUID.cast(daemon_id),
         {:ok, credential_id} <- Ecto.UUID.cast(credential_id),
         {daemon, credential} <-
           Repo.one(
             from d in Daemon,
               join: c in DaemonCredential,
               on: c.daemon_id == d.id,
               where:
                 d.id == ^daemon_id and c.id == ^credential_id and c.credential_kind == "access",
               select: {d, c}
           ),
         true <- Daemon.credential_eligible?(daemon),
         true <- DaemonCredential.valid_for_authentication?(credential, now(opts)) do
      {:ok, daemon, credential}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  defp issue_pair!(daemon_id, now, predecessor_refresh_id) do
    access_token = new_token()
    refresh_token = new_token()

    refresh =
      insert_credential!(
        daemon_id,
        "refresh",
        DaemonCredential.hash_token(refresh_token),
        DateTime.add(now, @refresh_ttl_seconds),
        predecessor_refresh_id
      )

    access =
      insert_credential!(
        daemon_id,
        "access",
        DaemonCredential.hash_token(access_token),
        DateTime.add(now, @access_ttl_seconds),
        refresh.id
      )

    {%{
       access_token: access_token,
       access_expires_at: access.expires_at,
       refresh_token: refresh_token,
       refresh_expires_at: refresh.expires_at
     }, refresh}
  end

  defp revoke_credentials!(query, now) do
    Repo.update_all(query, set: [status: "revoked", revoked_at: now, updated_at: now])
  end

  defp record_enrollment!(%Daemon{enrolled_at: %DateTime{}} = daemon, _now), do: daemon

  defp record_enrollment!(%Daemon{} = daemon, now) do
    case Repo.update(Daemon.enroll_changeset(daemon, now)) do
      {:ok, daemon} -> daemon
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp lock_daemon!(daemon_id) do
    daemon = lock_daemon_row!(daemon_id)

    if Daemon.credential_eligible?(daemon) do
      daemon
    else
      Repo.rollback(:invalid_credentials)
    end
  end

  defp lock_daemon_row!(daemon_id) do
    case Repo.one(from d in Daemon, where: d.id == ^daemon_id, lock: "FOR UPDATE") do
      %Daemon{} = daemon -> daemon
      _ -> Repo.rollback(:invalid_credentials)
    end
  end

  defp lock_daemon_for_delete!(daemon_id) do
    case Repo.one(from d in Daemon, where: d.id == ^daemon_id, lock: "FOR UPDATE") do
      %Daemon{} = daemon -> daemon
      _ -> Repo.rollback(:not_found)
    end
  end

  defp invalidate_active_credentials(daemon_id, now) do
    Repo.update_all(
      from(c in DaemonCredential, where: c.daemon_id == ^daemon_id and c.status == "active"),
      set: [status: "revoked", revoked_at: now, updated_at: now]
    )
  end

  defp lifecycle_result(daemon),
    do: %{daemon: daemon, credential: nil, token: nil}

  defp insert_credential!(daemon_id, kind, token_hash, expires_at, predecessor_id \\ nil) do
    changeset =
      DaemonCredential.create_changeset(
        %DaemonCredential{
          daemon_id: daemon_id,
          credential_kind: kind,
          predecessor_id: predecessor_id
        },
        %{token_hash: token_hash, expires_at: expires_at}
      )

    case Repo.insert(changeset, log: false) do
      {:ok, credential} -> credential
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp new_token,
    do: "sacd_" <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
end
