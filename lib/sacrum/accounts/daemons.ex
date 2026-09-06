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

  @spec revoke(String.t(), String.t()) ::
          {:ok, Daemon.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def revoke(user_id, daemon_id) do
    with {:ok, daemon} <- get_by(user_id, conditions: [id: daemon_id]) do
      DaemonsRepo.revoke(daemon)
    end
  end

  @spec rotate(String.t(), String.t()) ::
          {:ok, Daemon.t(), String.t()}
          | {:error, :not_found | :invalid_credentials | Ecto.Changeset.t()}
  def rotate(user_id, daemon_id) do
    with {:ok, daemon} <- get_by(user_id, conditions: [id: daemon_id]) do
      DaemonsRepo.rotate(daemon)
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
          | {:error, :not_found | :invalid_credentials | Ecto.Changeset.t()}
  def rotate_bootstrap(user_id, daemon_id) do
    with {:ok, daemon} <- get_by(user_id, conditions: [id: daemon_id]) do
      DaemonsRepo.rotate_bootstrap(daemon)
    end
  end
end
