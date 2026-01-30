defmodule Sacrum.Accounts.StepTransitions do
  @moduledoc """
  User-scoped step transition operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    schema: Sacrum.Repo.Schemas.StepTransition,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.StepTransitions, as: StepTransitionsRepo
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Broadcaster

  @doc """
  Insert a new step transition for a user.
  """
  def insert(user_id, attrs) when is_binary(user_id) do
    %StepTransition{user_id: user_id}
    |> StepTransition.create_changeset(attrs)
    |> StepTransitionsRepo.insert()
    |> Broadcaster.broadcast(:step_transition_created, from_step: [workflow: :project])
  end

  @doc """
  Delete a step transition.
  """
  def delete(%StepTransition{} = transition) do
    case StepTransitionsRepo.delete(transition) do
      {:ok, deleted} ->
        Broadcaster.broadcast_event(deleted, :step_transition_deleted,
          from_step: [workflow: :project]
        )

        {:ok, deleted}

      error ->
        error
    end
  end
end
