defmodule Sacrum.Accounts.WorkflowTransitions do
  @moduledoc """
  User-scoped workflow transition operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.WorkflowTransitions,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.WorkflowTransition
  alias Sacrum.Repo.WorkflowTransitions, as: WorkflowTransitionsRepo

  @doc """
  Insert a new workflow transition for a user.
  Extracts from_workflow_id, to_workflow_id, and project_id from attrs.
  """
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    from_workflow_id = Map.get(attrs, "from_workflow_id") || Map.get(attrs, :from_workflow_id)
    to_workflow_id = Map.get(attrs, "to_workflow_id") || Map.get(attrs, :to_workflow_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    %WorkflowTransition{
      user_id: user_id,
      from_workflow_id: from_workflow_id,
      to_workflow_id: to_workflow_id,
      project_id: project_id
    }
    |> WorkflowTransition.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Delete a workflow transition.
  """
  def delete(%WorkflowTransition{} = transition) do
    WorkflowTransitionsRepo.delete(transition)
  end
end
