defmodule Sacrum.Accounts.SessionLogs do
  @moduledoc """
  User-scoped session log operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.SessionLogs,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.Schemas.SessionLog

  @doc """
  Insert a new session log for a user.
  Extracts step_execution_id and project_id from attrs.
  """
  @spec insert(String.t(), map()) :: {:ok, SessionLog.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    RepoModule.insert(user_id, attrs)
  end

  @doc """
  Update an existing session log.
  """
  @spec update(SessionLog.t(), map()) :: {:ok, SessionLog.t()} | {:error, Ecto.Changeset.t()}
  def update(%SessionLog{} = log, attrs) when is_map(attrs) do
    RepoModule.update(log, attrs)
  end
end
