defmodule Sacrum.Accounts.Workflows do
  @moduledoc """
  User-scoped workflow operations with business logic.

  All operations are scoped to a specific user. Includes transition syncing
  and broadcast support.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.Workflows,
    preloads: [:transitions],
    default_order: [asc: :display_order, asc: :inserted_at]

  alias Sacrum.Repo.Workflows, as: WorkflowsRepo
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Broadcaster

  @doc """
  Insert a new workflow for a user within a project.
  Accepts either (project_struct, attrs) or (user_id, project_id, attrs).
  """
  def insert(%{id: project_id, user_id: user_id}, attrs) do
    insert(user_id, project_id, attrs)
  end

  def insert(user_id, project_id, attrs) when is_binary(user_id) and is_binary(project_id) do
    %Workflow{project_id: project_id, user_id: user_id}
    |> Workflow.create_changeset(attrs)
    |> WorkflowsRepo.insert()
    |> Broadcaster.broadcast(:workflow_created, :project)
  end

  @doc """
  Update a workflow.
  """
  def update(%Workflow{} = workflow, attrs) do
    workflow
    |> Workflow.update_changeset(attrs)
    |> WorkflowsRepo.update()
    |> Broadcaster.broadcast(:workflow_updated, :project)
  end

  @doc """
  Delete a workflow.
  """
  def delete(%Workflow{} = workflow) do
    case WorkflowsRepo.delete(workflow) do
      {:ok, deleted} ->
        Broadcaster.broadcast_event(deleted, :workflow_deleted, :project)
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Syncs the transitions for a workflow.
  """
  def sync_transitions(%Workflow{} = workflow, transition_maps) when is_list(transition_maps) do
    WorkflowsRepo.sync_transitions(workflow, transition_maps)
  end
end
