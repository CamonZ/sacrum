defmodule Sacrum.Repo.StepExecutions do
  @moduledoc """
  Operations for step execution audit trail.

  ## Error Contract

  - `get/1` returns `{:ok, execution}` or `{:error, :not_found}`
  - `get!/1` returns execution or raises
  - `get_by/1` returns `{:ok, execution}` or `{:error, :not_found}`
  - `all/0` returns `[execution]`
  - `insert/1` returns `{:ok, execution}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.StepExecution

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Broadcaster

  @doc """
  Insert a new step execution with user_id.
  Extracts task_id and project_id from attrs.
  """
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    task_id = Map.get(attrs, "task_id") || Map.get(attrs, :task_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    %StepExecution{user_id: user_id, task_id: task_id, project_id: project_id}
    |> StepExecution.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_step_execution(:step_execution_created)
  end

  defoverridable insert: 2
end
