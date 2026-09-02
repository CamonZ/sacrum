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
          {:ok, Daemon.t(), String.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rotate(user_id, daemon_id) do
    with {:ok, daemon} <- get_by(user_id, conditions: [id: daemon_id]) do
      DaemonsRepo.rotate(daemon)
    end
  end
end
