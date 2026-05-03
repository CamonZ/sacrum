defmodule Sacrum.Accounts.WorkflowTransitions do
  @moduledoc """
  User-scoped workflow transition operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.WorkflowTransitions,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.WorkflowTransition
  alias Sacrum.Repo.WorkflowTransitions, as: WorkflowTransitionsRepo

  @doc """
  Insert a new workflow transition for a user.
  Extracts from_workflow_id, to_workflow_id, and project_id from attrs.
  """
  @spec insert(String.t(), map()) ::
          {:ok, WorkflowTransition.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    user_id
    |> WorkflowTransitionsRepo.insert(attrs)
    |> Broadcaster.broadcast(:workflow_transition_created, :project)
  end

  @doc """
  Delete a workflow transition.
  """
  @spec delete(WorkflowTransition.t()) ::
          {:ok, WorkflowTransition.t()} | {:error, Ecto.Changeset.t()}
  def delete(%WorkflowTransition{} = transition) do
    case WorkflowTransitionsRepo.delete(transition) do
      {:ok, deleted} ->
        Broadcaster.broadcast_event(deleted, :workflow_transition_deleted, :project)
        {:ok, deleted}

      error ->
        error
    end
  end
end
