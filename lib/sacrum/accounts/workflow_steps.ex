defmodule Sacrum.Accounts.WorkflowSteps do
  @moduledoc """
  User-scoped workflow step operations with business logic.

  All operations are scoped to a specific user. Includes transition syncing
  and broadcast support.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.WorkflowSteps,
    preloads: [],
    default_order: [asc: :step_order, asc: :inserted_at]

  alias Sacrum.Repo.WorkflowSteps, as: WorkflowStepsRepo
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Broadcaster

  @doc """
  Insert a new workflow step for a user within a workflow.
  Accepts either (workflow_struct, attrs) or (user_id, workflow_id, attrs).
  """
  def insert(%{id: workflow_id, user_id: user_id}, attrs) do
    insert(user_id, workflow_id, attrs)
  end

  def insert(user_id, workflow_id, attrs) when is_binary(user_id) and is_binary(workflow_id) do
    %WorkflowStep{workflow_id: workflow_id, user_id: user_id}
    |> WorkflowStep.create_changeset(attrs)
    |> WorkflowStepsRepo.insert()
    |> Broadcaster.broadcast(:step_created, workflow: :project)
  end

  @doc """
  Update a workflow step.
  """
  def update(%WorkflowStep{} = step, attrs) do
    step
    |> WorkflowStep.update_changeset(attrs)
    |> WorkflowStepsRepo.update()
    |> Broadcaster.broadcast(:step_updated, workflow: :project)
  end

  @doc """
  Delete a workflow step.
  """
  def delete(%WorkflowStep{} = step) do
    case WorkflowStepsRepo.delete(step) do
      {:ok, deleted} ->
        Broadcaster.broadcast_event(deleted, :step_deleted, workflow: :project)
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Syncs the outgoing transitions for a workflow step.
  """
  def sync_transitions(%WorkflowStep{} = step, transitions) when is_list(transitions) do
    WorkflowStepsRepo.sync_transitions(step, transitions)
  end
end
