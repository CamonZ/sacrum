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
  alias Sacrum.Repo.WorkflowTransitions, as: WorkflowTransitionsRepo
  alias Sacrum.Repo.Schemas.WorkflowTransition

  @doc """
  Insert a new workflow transition for a user.
  """
  def insert(user_id, attrs) when is_binary(user_id) do
    %WorkflowTransition{user_id: user_id}
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
