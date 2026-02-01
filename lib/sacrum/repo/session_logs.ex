defmodule Sacrum.Repo.SessionLogs do
  @moduledoc """
  Operations for session logs within step executions.

  ## Error Contract

  - `get/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `get!/1` returns log or raises
  - `get_by/1` returns `{:ok, log}` or `{:error, :not_found}`
  - `all/0` returns `[log]`
  - `insert/1` returns `{:ok, log}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.SessionLog

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.SessionLog

  @doc """
  Insert a new session log from attrs map.
  """
  def insert(attrs) when is_map(attrs) do
    %SessionLog{}
    |> SessionLog.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Insert a new session log with user_id.
  """
  def insert(user_id, attrs) when is_binary(user_id) do
    %SessionLog{user_id: user_id}
    |> SessionLog.create_changeset(attrs)
    |> Repo.insert()
  end

  defoverridable insert: 1, insert: 2
end
