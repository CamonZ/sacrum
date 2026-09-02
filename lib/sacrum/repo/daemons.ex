defmodule Sacrum.Repo.Daemons do
  @moduledoc "Database operations for daemon provisioning and credentials."

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Daemon

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.DaemonCredentials
  alias Sacrum.Repo.Schemas.{Daemon, DaemonCredential, User}

  @token_bytes 32
  @default_ttl 86_400

  @spec create(User.t() | String.t() | Daemon.t()) ::
          {:ok, Daemon.t(), String.t()} | {:error, Ecto.Changeset.t()}
  @spec create(User.t() | String.t() | Daemon.t(), map()) ::
          {:ok, Daemon.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create(user_or_daemon, attrs \\ %{})
  def create(%User{id: user_id}, attrs), do: create(%Daemon{user_id: user_id}, attrs)

  def create(%Daemon{} = daemon, attrs) do
    token = "sacd_" <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), Map.get(attrs, :ttl, @default_ttl), :second)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:daemon, Daemon.create_changeset(daemon, attrs))
      |> Ecto.Multi.insert(:credential, fn %{daemon: daemon} ->
        DaemonCredential.create_changeset(%DaemonCredential{daemon_id: daemon.id}, %{
          token_hash: Argon2.hash_pwd_salt(token),
          expires_at: expires_at
        })
      end)

    case Repo.transaction(multi) do
      {:ok, %{daemon: daemon}} -> {:ok, daemon, token}
      {:error, _step, changeset, _changes} -> {:error, changeset}
    end
  end

  def create(user_id, attrs) when is_binary(user_id), do: create(%Daemon{user_id: user_id}, attrs)

  @spec revoke(Daemon.t()) :: {:ok, Daemon.t()} | {:error, Ecto.Changeset.t()}
  def revoke(%Daemon{} = daemon) do
    Repo.update(Daemon.update_changeset(daemon, %{status: "revoked"}))
  end

  @spec rotate(Daemon.t()) :: {:ok, Daemon.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def rotate(%Daemon{} = daemon) do
    token = "sacd_" <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), @default_ttl, :second)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.update_all(
        :revoke,
        from(c in DaemonCredential, where: c.daemon_id == ^daemon.id and c.status == "active"),
        set: [status: "revoked", revoked_at: DateTime.utc_now()]
      )
      |> Ecto.Multi.insert(:credential, fn _ ->
        DaemonCredential.create_changeset(%DaemonCredential{daemon_id: daemon.id}, %{
          token_hash: Argon2.hash_pwd_salt(token),
          expires_at: expires_at
        })
      end)

    case Repo.transaction(multi) do
      {:ok, _} -> {:ok, daemon, token}
      {:error, _, changeset, _} -> {:error, changeset}
    end
  end

  @spec verify_token(String.t(), String.t()) :: {:ok, Daemon.t()} | {:error, :invalid_credentials}
  def verify_token(daemon_id, token) when is_binary(daemon_id) and is_binary(token) do
    credentials = DaemonCredentials.list_active_for_daemon(daemon_id)

    case Enum.find(credentials, fn c ->
           DateTime.compare(c.expires_at, DateTime.utc_now()) == :gt &&
             Argon2.verify_pass(token, c.token_hash)
         end) do
      nil -> {:error, :invalid_credentials}
      credential -> {:ok, Repo.get!(Daemon, credential.daemon_id)}
    end
  end

  def verify_token(_, _), do: {:error, :invalid_credentials}
end
