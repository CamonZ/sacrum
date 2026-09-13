defmodule Sacrum.Repo.Daemons do
  @moduledoc "Database operations for daemon provisioning and credentials."

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Daemon

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.DaemonCredentials
  alias Sacrum.Repo.Schemas.{Daemon, DaemonCredential, User}

  @token_bytes 32
  @default_ttl 86_400
  @reconnect_ttl_seconds 2_592_000

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

  @spec create_bootstrap(User.t() | String.t() | Daemon.t(), map()) ::
          {:ok, Daemon.t(), String.t(), DaemonCredential.t()} | {:error, Ecto.Changeset.t()}
  def create_bootstrap(user_or_daemon, attrs \\ %{})

  def create_bootstrap(%User{id: user_id}, attrs),
    do: create_bootstrap(%Daemon{user_id: user_id}, attrs)

  def create_bootstrap(%Daemon{} = daemon, attrs) do
    token = new_token()
    token_hash = Argon2.hash_pwd_salt(token)
    expires_at = DateTime.add(DateTime.utc_now(), Map.get(attrs, :ttl, @default_ttl), :second)

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

  def create_bootstrap(user_id, attrs) when is_binary(user_id),
    do: create_bootstrap(%Daemon{user_id: user_id}, attrs)

  @doc """
  Deletes a daemon under its row lock and transaction.

  The lock is shared with bootstrap exchange and credential rotation, so a
  committed delete always wins over any credentials issued by a contending
  lifecycle operation. The daemon foreign key owns credential cleanup through
  `ON DELETE CASCADE`; no credential rows are retained or manually revoked.

  Callers that have an authoritative daemon-keyed work guard can pass an
  `active_work?` function. A connected session alone is not a database work
  reference: successful deletion invalidates it after commit.
  """
  @spec delete(Daemon.t()) ::
          {:ok, committed_lifecycle()}
          | {:error, :not_found | :active_work | Ecto.Changeset.t()}
  @spec delete(Daemon.t(), keyword()) ::
          {:ok, committed_lifecycle()}
          | {:error, :not_found | :active_work | Ecto.Changeset.t()}
  def delete(%Daemon{} = daemon), do: delete(daemon, [])

  def delete(%Daemon{} = daemon, opts) when is_list(opts) do
    Repo.transaction(fn ->
      daemon = lock_daemon_for_delete!(daemon.id)

      if active_work?(opts, daemon), do: Repo.rollback(:active_work)

      delete_locked!(daemon)
    end)
  end

  defp connected?(opts, daemon) do
    case Keyword.get(opts, :connected?) do
      fun when is_function(fun, 1) -> fun.(daemon)
      _ -> false
    end
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

  @doc """
  Legacy unregister compatibility path.

  Unregister keeps the historical conservative refusal boundary while the
  daemon-keyed work ownership contract is unavailable: connected sessions
  return `:active_work`, and any enrollment evidence returns
  `:ownership_unknown`. A never-enrolled daemon is hard-deleted. New callers
  should use `delete/2`, which invalidates connected sessions after commit.
  """
  @spec unregister(Daemon.t()) ::
          {:ok, committed_lifecycle()}
          | {:error, :not_found | :ownership_unknown | :active_work | Ecto.Changeset.t()}
  @spec unregister(Daemon.t(), keyword()) ::
          {:ok, committed_lifecycle()}
          | {:error, :not_found | :ownership_unknown | :active_work | Ecto.Changeset.t()}
  def unregister(%Daemon{} = daemon, opts \\ []) do
    Repo.transaction(fn ->
      daemon = lock_daemon_for_delete!(daemon.id)

      cond do
        connected?(opts, daemon) ->
          Repo.rollback(:active_work)

        enrollment_evidence?(daemon.id) ->
          Repo.rollback(:ownership_unknown)

        true ->
          delete_locked!(daemon)
      end
    end)
  end

  defp enrollment_evidence?(daemon_id) do
    Repo.exists?(
      from c in DaemonCredential,
        where:
          c.daemon_id == ^daemon_id and
            (c.credential_kind == "reconnect" or not is_nil(c.consumed_at))
    )
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
    token_hash = Argon2.hash_pwd_salt(token)

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
  Exchanges a bootstrap exactly once, returning the existing daemon and a new
  reconnect token plus its metadata. Only the successful response contains the
  plaintext. A lost response requires owner-authorized rotation and a new exchange.

  The optional `:now` DateTime is a deterministic deadline seam for trusted callers.
  Production callers omit it so validity is checked again after acquiring locks.
  """
  @spec exchange_bootstrap(term(), term(), keyword()) ::
          {:ok, Daemon.t(), String.t(), DaemonCredential.t()}
          | {:error, :invalid_credentials | Ecto.Changeset.t()}
  def exchange_bootstrap(daemon_id, token, opts \\ [])

  def exchange_bootstrap(daemon_id, token, opts) when is_binary(daemon_id) and is_binary(token) do
    with {:ok, daemon_id} <- Ecto.UUID.cast(daemon_id),
         %DaemonCredential{} = bootstrap <-
           matching_credential(daemon_id, token, "bootstrap", now(opts)) do
      # Expensive hashing happens before locks; mutable validity is rechecked below.
      reconnect_token = new_token()
      reconnect_hash = Argon2.hash_pwd_salt(reconnect_token)

      result = exchange_credential(daemon_id, bootstrap.id, reconnect_hash, opts)

      case result do
        {:ok, {daemon, reconnect}} -> {:ok, daemon, reconnect_token, reconnect}
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def exchange_bootstrap(_, _, _), do: {:error, :invalid_credentials}

  @spec verify_token(term(), term(), keyword()) ::
          {:ok, Daemon.t()} | {:error, :invalid_credentials}
  def verify_token(daemon_id, token, opts \\ []) do
    case authenticate_reconnect(daemon_id, token, opts) do
      {:ok, daemon, _credential} -> {:ok, daemon}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec authenticate_reconnect(term(), term(), keyword()) ::
          {:ok, Daemon.t(), DaemonCredential.t()} | {:error, :invalid_credentials}
  def authenticate_reconnect(daemon_id, token, opts \\ [])

  def authenticate_reconnect(daemon_id, token, opts)
      when is_binary(daemon_id) and is_binary(token) do
    with {:ok, daemon_id} <- Ecto.UUID.cast(daemon_id),
         %DaemonCredential{} = credential <-
           matching_credential(daemon_id, token, "reconnect", now(opts)) do
      revalidate_reconnect(daemon_id, credential.id, opts)
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def authenticate_reconnect(_, _, _), do: {:error, :invalid_credentials}

  @doc "Rechecks an already authenticated credential by persisted identity without retaining plaintext."
  @spec revalidate_reconnect(term(), term(), keyword()) ::
          {:ok, Daemon.t(), DaemonCredential.t()} | {:error, :invalid_credentials}
  def revalidate_reconnect(daemon_id, credential_id, opts \\ []) do
    with {:ok, daemon_id} <- Ecto.UUID.cast(daemon_id),
         {:ok, credential_id} <- Ecto.UUID.cast(credential_id),
         {daemon, credential} <-
           Repo.one(
             from d in Daemon,
               join: c in DaemonCredential,
               on: c.daemon_id == d.id,
               where:
                 d.id == ^daemon_id and c.id == ^credential_id and
                   c.credential_kind == "reconnect",
               select: {d, c}
           ),
         true <- Daemon.credential_eligible?(daemon),
         true <- DaemonCredential.valid_for_authentication?(credential, now(opts)) do
      {:ok, daemon, credential}
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  defp exchange_credential(daemon_id, bootstrap_id, reconnect_hash, opts) do
    Repo.transaction(fn ->
      daemon = lock_daemon!(daemon_id)

      bootstrap =
        Repo.one(from c in DaemonCredential, where: c.id == ^bootstrap_id, lock: "FOR UPDATE")

      now = now(opts)

      changeset = bootstrap && DaemonCredential.consume_changeset(bootstrap, now)

      unless changeset && changeset.valid?,
        do: Repo.rollback(:invalid_credentials)

      Repo.update!(changeset)

      reconnect =
        insert_credential!(
          daemon.id,
          "reconnect",
          reconnect_hash,
          DateTime.add(now, @reconnect_ttl_seconds)
        )

      daemon = record_enrollment!(daemon, now)

      {daemon, reconnect}
    end)
  end

  defp record_enrollment!(%Daemon{enrolled_at: %DateTime{}} = daemon, _now), do: daemon

  defp record_enrollment!(%Daemon{} = daemon, now) do
    case Repo.update(Daemon.enroll_changeset(daemon, now)) do
      {:ok, daemon} -> daemon
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp matching_credential(daemon_id, token, kind, now) do
    candidates =
      daemon_id
      |> DaemonCredentials.list_active_for_daemon()
      |> Enum.filter(fn credential ->
        credential.credential_kind == kind and
          DaemonCredential.valid_for_authentication?(credential, now)
      end)

    case candidates do
      [] ->
        # Same Argon2 work as a mismatch so missing credentials are not a timing oracle.
        Argon2.no_user_verify()
        nil

      _ ->
        Enum.find(candidates, &Argon2.verify_pass(token, &1.token_hash))
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

  defp insert_credential!(daemon_id, kind, token_hash, expires_at) do
    changeset =
      DaemonCredential.create_changeset(
        %DaemonCredential{daemon_id: daemon_id, credential_kind: kind},
        %{token_hash: token_hash, expires_at: expires_at}
      )

    case Repo.insert(changeset) do
      {:ok, credential} -> credential
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp new_token,
    do: "sacd_" <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
end
