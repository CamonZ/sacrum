defmodule Sacrum.Accounts.StepExecutions do
  @moduledoc """
  User-scoped step execution operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.StepExecutions,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepExecution

  @doc """
  Insert a new step execution for a user.
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

  @doc """
  Update an existing step execution.
  Applies the update_changeset and broadcasts the status change event.
  """
  def update(%StepExecution{} = execution, attrs) do
    execution
    |> StepExecution.update_changeset(attrs)
    |> Repo.update()
    |> Broadcaster.broadcast_step_execution(:step_execution_status_changed)
  end
end
