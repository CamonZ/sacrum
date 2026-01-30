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

  def list_for_task(task_id) when is_binary(task_id) do
    from(e in StepExecution,
      where: e.task_id == ^task_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  def list_for_task(task_id, user_id) when is_binary(task_id) and is_binary(user_id) do
    from(e in StepExecution,
      where: e.task_id == ^task_id and e.user_id == ^user_id,
      order_by: [asc: e.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Insert a new step execution from attrs map.
  """
  def insert(attrs) when is_map(attrs) do
    %StepExecution{}
    |> StepExecution.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_step_execution(:step_execution_created)
  end

  @doc """
  Insert a new step execution with user_id.
  """
  def insert(user_id, attrs) when is_binary(user_id) do
    %StepExecution{user_id: user_id}
    |> StepExecution.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_step_execution(:step_execution_created)
  end

  defoverridable insert: 1, insert: 2
end
