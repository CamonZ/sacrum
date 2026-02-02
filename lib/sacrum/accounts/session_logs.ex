defmodule Sacrum.Accounts.SessionLogs do
  @moduledoc """
  User-scoped session log operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.SessionLogs,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.SessionLog
  alias Sacrum.Repo.Broadcaster

  @doc """
  Insert a new session log for a user.
  """
  def insert(user_id, attrs) when is_binary(user_id) do
    %SessionLog{user_id: user_id}
    |> SessionLog.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_session_log(:session_log_created)
  end
end
