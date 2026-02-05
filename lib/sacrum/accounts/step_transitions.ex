defmodule Sacrum.Accounts.StepTransitions do
  @moduledoc """
  User-scoped step transition operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.StepTransitions,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.StepTransitions, as: StepTransitionsRepo
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Broadcaster

  @doc """
  Insert a new step transition for a user.
  Extracts from_step_id, to_step_id, and project_id from attrs.
  """
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    from_step_id = Map.get(attrs, "from_step_id") || Map.get(attrs, :from_step_id)
    to_step_id = Map.get(attrs, "to_step_id") || Map.get(attrs, :to_step_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    %StepTransition{
      user_id: user_id,
      from_step_id: from_step_id,
      to_step_id: to_step_id,
      project_id: project_id
    }
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
