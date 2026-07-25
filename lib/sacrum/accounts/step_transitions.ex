defmodule Sacrum.Accounts.StepTransitions do
  @moduledoc """
  User-scoped step transition operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.StepTransitions,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.StepTransitions, as: StepTransitionsRepo

  @doc """
  Insert a new step transition for a user.
  Extracts from_step_id, to_step_id, and project_id from attrs.
  """
  @spec insert(String.t(), map()) ::
          {:ok, StepTransition.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    StepTransitionsRepo.insert(user_id, attrs)
  end

  @doc """
  Delete a step transition.
  """
  @spec delete(StepTransition.t()) :: {:ok, StepTransition.t()} | {:error, Ecto.Changeset.t()}
  def delete(%StepTransition{} = transition) do
    StepTransitionsRepo.delete(transition)
  end
end
