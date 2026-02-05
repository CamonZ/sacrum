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
  Extracts step_execution_id and project_id from attrs.
  """
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    step_execution_id = Map.get(attrs, "step_execution_id") || Map.get(attrs, :step_execution_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    %SessionLog{user_id: user_id, step_execution_id: step_execution_id, project_id: project_id}
    |> SessionLog.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_session_log(:session_log_created)
  end
end
