defmodule Sacrum.Accounts.StepExecutions do
  @moduledoc """
  User-scoped step execution operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    schema: Sacrum.Repo.Schemas.StepExecution,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.StepExecutions, as: StepExecutionsRepo
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Broadcaster

  @doc """
  Insert a new step execution for a user.
  """
  def insert(user_id, attrs) when is_binary(user_id) do
    %StepExecution{user_id: user_id}
    |> StepExecution.create_changeset(attrs)
    |> StepExecutionsRepo.insert()
    |> Broadcaster.broadcast_step_execution(:step_execution_created)
  end
end
