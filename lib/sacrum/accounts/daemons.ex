defmodule Sacrum.Accounts.Daemons do
  @moduledoc "User-scoped daemon provisioning operations."

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.Daemons,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.Daemons, as: DaemonsRepo
  alias Sacrum.Repo.Schemas.Daemon

  @spec create(String.t()) :: {:ok, Daemon.t(), String.t()} | {:error, Ecto.Changeset.t()}
  @spec create(String.t(), map()) :: {:ok, Daemon.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create(user_id, attrs \\ %{}), do: DaemonsRepo.create(%Daemon{user_id: user_id}, attrs)

  @doc """
  Owner-scoped revocation. Session invalidation is post-commit and best-effort;
  a delivery failure does not roll back the mutation. A tombstone stays removed.
  """
  @spec revoke(String.t(), String.t()) ::
          {:ok, Daemon.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke(user_id, daemon_id) do
    with {:ok, daemon} <- get_by(user_id, conditions: [id: daemon_id]) do
      case DaemonsRepo.revoke(daemon) do
        {:ok, %{daemon: daemon}} ->
          Sacrum.DaemonConnectionRegistry.invalidate_sessions(daemon.id)
          {:ok, daemon}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  @doc "Owner-scoped rename. Terminal identities cannot be renamed."
  @spec rename(String.t(), String.t(), map()) ::
          {:ok, Daemon.t()}
          | {:error, :not_found | :terminal_state | Ecto.Changeset.t()}
  def rename(user_id, daemon_id, attrs) do
    with {:ok, daemon} <- get_by(user_id, conditions: [id: daemon_id]) do
      DaemonsRepo.rename(daemon, attrs)
    end
  end

  @doc """
  Owner-scoped unregister. Connected sessions refuse with `:active_work`;
  enrollment evidence refuses with `:ownership_unknown`. Never-enrolled
  provisioning is tombstoned. Already-removed rows are idempotent.
  """
  @spec unregister(String.t(), String.t()) ::
          {:ok, Daemon.t()}
          | {:error, :not_found | :active_work | :ownership_unknown | Ecto.Changeset.t()}
  def unregister(user_id, daemon_id) do
    with {:ok, daemon} <- get_by(user_id, conditions: [id: daemon_id]) do
      case DaemonsRepo.unregister(daemon, connected?: &session_connected?/1) do
        {:ok, %{daemon: removed}} ->
          Sacrum.DaemonConnectionRegistry.invalidate_sessions(removed.id)
          {:ok, removed}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp session_connected?(%Daemon{id: id}),
    do: Sacrum.DaemonConnectionRegistry.lookup(id) != []

  @doc "Owner's daemons excluding removed tombstones. Tombstones remain readable via `get_by/2`."
  @spec list_fleet(String.t()) :: [Daemon.t()]
  def list_fleet(user_id) when is_binary(user_id), do: DaemonsRepo.list_active_fleet(user_id)

  @spec list_by(String.t()) :: [Daemon.t()]
  def list_by(user_id) when is_binary(user_id), do: list_fleet(user_id)

  @doc "Owner-scoped enrollment metadata without token material."
  @spec enrollment(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def enrollment(user_id, daemon_id) do
    case get_by(user_id, conditions: [id: daemon_id]) do
      {:ok, daemon} -> {:ok, DaemonsRepo.enrollment_metadata(daemon)}
      {:error, :not_found} = error -> error
    end
  end

  @spec rotate(String.t(), String.t()) ::
          {:ok, Daemon.t(), String.t()}
          | {:error, :not_found | :invalid_credentials | :terminal_state | Ecto.Changeset.t()}
  def rotate(user_id, daemon_id) do
    case rotate_bootstrap(user_id, daemon_id) do
      {:ok, daemon, token, _credential} -> {:ok, daemon, token}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Authenticates the bootstrap itself; ownership is derived from its persisted daemon."
  @spec exchange_bootstrap(term(), term(), keyword()) ::
          {:ok, Daemon.t(), String.t(), Sacrum.Repo.Schemas.DaemonCredential.t()}
          | {:error, :invalid_credentials | Ecto.Changeset.t()}
  def exchange_bootstrap(daemon_id, token, opts \\ []),
    do: DaemonsRepo.exchange_bootstrap(daemon_id, token, opts)

  @spec create_bootstrap(String.t(), map()) ::
          {:ok, Daemon.t(), String.t(), Sacrum.Repo.Schemas.DaemonCredential.t()}
          | {:error, Ecto.Changeset.t()}
  def create_bootstrap(user_id, attrs \\ %{}),
    do: DaemonsRepo.create_bootstrap(%Daemon{user_id: user_id}, attrs)

  @spec rotate_bootstrap(String.t(), String.t()) ::
          {:ok, Daemon.t(), String.t(), Sacrum.Repo.Schemas.DaemonCredential.t()}
          | {:error, :not_found | :invalid_credentials | :terminal_state | Ecto.Changeset.t()}
  def rotate_bootstrap(user_id, daemon_id) do
    with {:ok, daemon} <- get_by(user_id, conditions: [id: daemon_id]) do
      case DaemonsRepo.rotate_bootstrap(daemon) do
        {:ok, %{daemon: daemon, token: token, credential: credential}} ->
          Sacrum.DaemonConnectionRegistry.invalidate_sessions(daemon.id)
          {:ok, daemon, token, credential}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
