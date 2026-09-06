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

  @spec revoke(Daemon.t()) :: {:ok, Daemon.t()} | {:error, Ecto.Changeset.t()}
  def revoke(%Daemon{} = daemon) do
    Repo.update(Daemon.update_changeset(daemon, %{status: "revoked"}))
  end

  @doc "Revokes all prior credentials and issues a fresh bootstrap on the same identity."
  @spec rotate(Daemon.t()) ::
          {:ok, Daemon.t(), String.t()} | {:error, :invalid_credentials | Ecto.Changeset.t()}
  def rotate(%Daemon{} = daemon) do
    case rotate_bootstrap(daemon) do
      {:ok, daemon, token, _credential} -> {:ok, daemon, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec rotate_bootstrap(Daemon.t()) ::
          {:ok, Daemon.t(), String.t(), DaemonCredential.t()}
          | {:error, :invalid_credentials | Ecto.Changeset.t()}
  def rotate_bootstrap(%Daemon{} = daemon) do
    token = new_token()
    token_hash = Argon2.hash_pwd_salt(token)

    result =
      Repo.transaction(fn ->
        daemon = lock_daemon!(daemon.id)
        now = DateTime.utc_now()

        Repo.update_all(
          from(c in DaemonCredential, where: c.daemon_id == ^daemon.id and c.status == "active"),
          set: [status: "revoked", revoked_at: now, updated_at: now]
        )

        credential =
          insert_credential!(daemon.id, "bootstrap", token_hash, DateTime.add(now, @default_ttl))

        {daemon, credential}
      end)

    case result do
      {:ok, {daemon, credential}} -> {:ok, daemon, token, credential}
      {:error, reason} -> {:error, reason}
    end
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
                 d.id == ^daemon_id and c.id == ^credential_id and d.status != "revoked" and
                   c.credential_kind == "reconnect",
               select: {d, c}
           ),
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

      {daemon, reconnect}
    end)
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
    case Repo.one(from d in Daemon, where: d.id == ^daemon_id, lock: "FOR UPDATE") do
      %Daemon{status: status} = daemon when status != "revoked" -> daemon
      _ -> Repo.rollback(:invalid_credentials)
    end
  end

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
